import Foundation

extension SharedCorrectness.Run {
    /// Replay a live DDL workload from its database baseline. Stop at a saved
    /// transaction boundary, then resume with an unreachable source.
    func replayDDLWorkflow(_ label:String,stopAfter:Int,from start:Boundary,to end:Boundary,stopGTIDs:String? = nil) throws {
        let original=f.config
        defer {f.config=original}
        var config=LabIsolatedApply(f).configuration(label+"-replay",at:start,count:stopAfter)
        var source=config["source"] as! [String:Any]
        source.removeValue(forKey:"stopAfterTransactions")
        config["source"]=source
        config["archive"]=["directory":"/evidence/"+label+"-archive","firstFile":start.file]
        f.config=config
        func invoke(_ label:String,_ command:String,initialize:Bool=false,success:Bool=true) throws -> [String:Any] {
            try f.installConfig(label)
            let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
            let exit=try f.runner.run(["docker","wait",client],timeout:120).text
            let logs=try f.docker(["logs",client])
            try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
            try require(success ? exit == "0" : exit != "0","DDL archive command failed; inspect "+label+".ndjson and support bundle")
            let bytes=command == "replay" ? logs.stderr : logs.stdout
            guard let line=bytes.split(separator:10).last,let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else {throw LabError("missing DDL archive summary")}
            return result
        }
        _ = try invoke(label+"-fetch","fetch")
        _ = try f.sql(.target,"SET sql_log_bin=0; DROP DATABASE ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        if f.variant != .withoutSourceGTIDs {_ = try f.sql(.target,f.profile.targetVersion.resetBinlogs+"; SET GLOBAL gtid_purged='\(start.gtids)'")}
        source["host"]="127.0.0.1";source["port"]=1
        source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
        if let stopGTIDs {source["stopAfterGTIDs"]=stopGTIDs} else {source["stopAfterTransactions"]=stopAfter}
        f.config["source"]=source
        let stopped=try invoke(label+"-replay-stop","replay",initialize:true)
        try require(stopped["transactionsApplied"] as? Int == stopAfter,"DDL replay stopped at the wrong transaction")
        if label == "keyless-rows" {
            // The stop point has two identical NULL rows. Remove one target
            // copy. The next source event updates both, so its second row must
            // fail after the first write. No new source event is needed.
            _ = try f.sql(.target,"SET sql_log_bin=0; DELETE FROM ddlcompat.t WHERE n IS NULL AND s IS NULL LIMIT 1")
            source["stopAfterTransactions"]=8;f.config["source"]=source
            let failed=try invoke(label+"-replay-missing","replay",success:false)
            try require((failed["reason"] as? String ?? "").contains("before-image mismatch"),"wrong keyless replay failure")
            let expected=f.profile.transactionalTarget ? "0" : "1"
            try require(f.sql(.target,"SELECT COUNT(*) FROM ddlcompat.t WHERE b=X'00'") == expected,"keyless partial-write or rollback result differs")
            let saved=f.output.appendingPathComponent("keyless-blocked")
            _ = try f.docker(["cp",f.helper+":"+(f.config["stateDirectory"] as! String),saved.path])
            let state=try f.runner.run(["sqlite3",saved.appendingPathComponent("state.sqlite").path,"SELECT lifecycle||'|'||transactions_applied||'|'||(SELECT COUNT(*) FROM row_intents WHERE status='PENDING' AND gtid=state.active_gtid) FROM state"]).text
            try require(state == "BLOCKED|7|2","keyless failure lost its pending rows or advanced progress")
            let refused=try invoke(label+"-replay-blocked","replay",success:false)
            try require((refused["reason"] as? String ?? "").contains("cleanly STOPPED"),"blocked keyless state resumed without DBA action")
            if f.profile.transactionalTarget {
                try f.installConfig()
                let report=try f.recovery(["inspect"],label:"keyless-recovery-inspect")
                guard let pending=report["pending"] as? [[String:Any]],!pending.isEmpty,
                      let changes=pending[0]["fullRowChanges"] as? [[String:Any]],changes.count == 2,
                      let expectations=pending[0]["expectations"] as? [Any],expectations.isEmpty,
                      let rows=pending[0]["rows"] as? [[String:Any]],rows.allSatisfy({$0["beforeKey"] == nil && $0["afterKey"] == nil}),
                      pending[0]["gtid"] is String else {throw LabError("keyless recovery lost duplicate operations")}
                let images=try changes.map { try JSONSerialization.data(withJSONObject:$0["before"]!,options:.sortedKeys) }
                try require(images[0] == images[1],"keyless recovery images differ")
                _ = try f.sql(.target,"SET sql_log_bin=0; INSERT INTO ddlcompat.t(n,s,b,j) VALUES(NULL,NULL,NULL,NULL)")
                // Retry names every durable pending group, including groups
                // prepared ahead of the failure but not sent to the target.
                var ids:[String:[String]]=[:]
                for group in pending {
                    guard let gtid=group["gtid"] as? String else {throw LabError("missing pending GTID")}
                    let parts=gtid.split(separator:":").map(String.init)
                    try require(parts.count == 2,"unexpected fixture GTID form")
                    ids[parts[0],default:[]].append(parts[1])
                }
                let gtids=ids.keys.sorted().map { $0+":"+ids[$0]!.joined(separator:":") }.joined(separator:",")
                _ = try f.recovery(["resolve","retry","--gtids",gtids,"--reason","fixture confirmed rollback and restored the missing duplicate"],label:"keyless-recovery-retry")
            } else {
                // Preserve the blocked state. This controlled fixture resets
                // the complete baseline and uses a new replay state.
                _ = try f.sql(.target,"SET sql_log_bin=0; DROP DATABASE ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
                if f.variant != .withoutSourceGTIDs {_ = try f.sql(.target,f.profile.targetVersion.resetBinlogs+"; SET GLOBAL gtid_purged='\(start.gtids)'")}
                f.config["stateDirectory"]="/evidence/keyless-reconciled-replay"
                source["stopAfterTransactions"]=7;f.config["source"]=source
                _ = try invoke(label+"-replay-reconciled","replay",initialize:true)
            }
        }
        source.removeValue(forKey:"stopAfterTransactions");source.removeValue(forKey:"stopAfterGTIDs");f.config["source"]=source
        let resumed=try invoke(label+"-replay-resume","replay")
        try require(resumed["appliedGTIDSet"] as? String == end.gtids,"DDL replay checkpoint differs")
        _ = try compare("ddlcompat")
        // Recovery uses apply.yaml. Restore the live writer's file before the
        // caller restarts it; restoring only f.config leaves replay credentials.
        f.config=original
        try f.installConfig()
    }
}
