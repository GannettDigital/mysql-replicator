import Foundation

extension SharedCorrectness.Run {
    func offlineSkipErrors() throws {
        guard selects("offline-skip-errors") else { return }
        try reporter.run(QualificationCase("offline-skip-errors","Replay skips whole groups, bounds optional audit and respects engine outcomes")) {
            try resetNativeEngine();try f.awaitNative()
            if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata=FULL") }
            let seed="SET sql_log_bin=0; DROP DATABASE IF EXISTS skip_poc; CREATE DATABASE skip_poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE skip_poc.items(id INT PRIMARY KEY,val INT)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,seed) }
            let begin=try f.boundary(),original=f.config
            defer { f.config=original }
            for sql in ["ALTER TABLE skip_poc.items ENABLE KEYS","INSERT INTO skip_poc.items VALUES(2,20)","INSERT INTO skip_poc.items VALUES(3,30),(4,40)","INSERT INTO skip_poc.items VALUES(5,50)"] {
                _ = try f.sql(.source,session+sql)
            }
            try f.awaitNative();let end=try f.boundary()
            var source=original["source"] as! [String:Any]
            source["mode"]="gtid";source["start"]=["file":begin.file,"position":begin.position,"executedGTIDs":begin.gtids]
            source.removeValue(forKey:"stopAfterTransactions");f.config["source"]=source
            f.config["archive"]=["directory":"/evidence/skip-archive","firstFile":begin.file]
            func invoke(_ label: String,_ command: String,initialize: Bool = false,success: Bool = true) throws -> [String:Any] {
                try f.installConfig(label)
                let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
                let code=try f.runner.run(["docker","wait",client],timeout:120).text
                let logs=try f.docker(["logs",client]);try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require((code == "0") == success,"unexpected skip replay exit: "+String(decoding:logs.stderr,as:UTF8.self))
                let bytes=command == "replay" ? logs.stderr : logs.stdout
                guard let line=bytes.split(separator:10).last,let report=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else {throw LabError("missing skip replay report")}
                return report
            }
            _ = try invoke("skip-fetch","fetch")
            source["host"]="unused.invalid";source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
            for audit in [false,true] {
                let label=audit ? "skip-audited" : "skip-counts"
                _ = try f.sql(.target,seed+"; INSERT INTO skip_poc.items VALUES(4,400)")
                f.config["stateDirectory"]="/evidence/"+label
                f.config["skipErrors"]=["codes":["ddl.unsupported_alter","mysql.1062"],"recordSkippedTransactions":audit]
                if f.profile == .reverse { source["stopAfterTransactions"]=3 }
                else { source.removeValue(forKey:"stopAfterTransactions") }
                f.config["source"]=source
                var result=try invoke(label,"replay",initialize:true,success:f.profile == .reverse)
                if f.profile == .reverse {
                    try require(result["transactionsApplied"] as? Int == 3,"skip stop limit did not count complete groups")
                    source.removeValue(forKey:"stopAfterTransactions");f.config["source"]=source
                    result=try invoke(label+"-resume","replay")
                    try require(result["appliedGTIDSet"] as? String == end.gtids && result["transactionsApplied"] as? Int == 4 && result["rowsApplied"] as? Int == 2,"skip resume checkpoint/counters differ")
                    try require(result["skippedTransactionsByCode"] as? [String:Int] == ["ddl.unsupported_alter":1,"mysql.1062":1],"skip counters did not survive resume")
                    try require(f.sql(.target,"SELECT id,val FROM skip_poc.items ORDER BY id") == "2\t20\n4\t400\n5\t50","duplicate source group was not fully rolled back before continuation")
                } else {
                    let progress=result["progress"] as? [String:Any] ?? [:]
                    try require(result["code"] as? String == "mysql.1062" && progress["lifecycle"] as? String == "BLOCKED" && progress["transactionsApplied"] as? Int == 2,"MyISAM duplicate was skipped or wrong prefix completed")
                    try require(progress["skippedTransactionsByCode"] as? [String:Int] == ["ddl.unsupported_alter":1],"MyISAM SQL failure entered skip counters")
                    try require(f.sql(.target,"SELECT COUNT(*) FROM skip_poc.items WHERE id=5") == "0","MyISAM continued after uncertain write")
                }
                _ = try f.docker(["cp",f.helper+":/evidence/"+label,f.output.path])
                let db=f.output.appendingPathComponent(label+"/state.sqlite").path
                let counts=try f.runner.run(["sqlite3",db,"SELECT COUNT(*) FROM error_skips; SELECT SUM(transactions) FROM error_skip_counts"]).text
                let skipped=f.profile == .reverse ? 2 : 1
                try require(counts == "\(audit ? skipped : 0)\n\(skipped)","optional audit retained incorrect rows: "+counts)
            }
        }
    }
}
