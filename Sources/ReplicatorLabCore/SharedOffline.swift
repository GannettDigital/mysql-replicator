import Foundation

extension SharedCorrectness.Run {
    func offline() throws {
        guard selects("offline-replay") else { return }
        try reporter.run(QualificationCase("offline-replay","Fetch and external mysqlbinlog archives replay DDL/DML, resume without source credentials, and produce a support bundle")) {
            try resetNativeEngine();try f.awaitNative()
            if f.profile.hasOptionalMetadata { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata) }
            let seed="SET sql_log_bin=0; DROP DATABASE IF EXISTS offline_poc; CREATE DATABASE offline_poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE offline_poc.aux(id INT PRIMARY KEY,val INT); INSERT INTO offline_poc.aux VALUES(1,10)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,seed) }
            let begin=try f.boundary(), original=f.config
            defer { f.config=original }
            for sql in ["ALTER TABLE offline_poc.aux ADD CONSTRAINT val_uni UNIQUE(val)","INSERT INTO offline_poc.aux VALUES(2,20),(3,30)","FLUSH BINARY LOGS","UPDATE offline_poc.aux SET val=21 WHERE id=2","ALTER TABLE offline_poc.aux ADD note VARCHAR(20) DEFAULT 'sensitive sample'","DELETE FROM offline_poc.aux WHERE id=3"] {
                _ = try f.sql(.source,session+sql)
            }
            try f.awaitNative();let end=try f.boundary()
            var source=original["source"] as! [String:Any]
            source["mode"]="gtid";source["start"]=["file":begin.file,"position":begin.position,"executedGTIDs":begin.gtids]
            source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source
            f.config["archive"]=["directory":"/evidence/fetched","firstFile":begin.file]
            f.config["stateDirectory"]="/evidence/offline-state"
            func invoke(_ label:String,_ command:String,initialize:Bool=false) throws -> [String:Any] {
                try f.installConfig(label)
                let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
                let code=try f.runner.run(["docker","wait",client],timeout:120).text
                let logs=try f.docker(["logs",client])
                try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(code == "0","offline command failed: "+String(decoding:logs.stderr,as:UTF8.self))
                let bytes=command == "replay" ? logs.stderr : logs.stdout
                guard let line=bytes.split(separator:10).last,let report=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing offline command report") }
                return report
            }
            let fetched=try invoke("offline-fetch","fetch")
            try require((fetched["files"] as? [[String:Any]] ?? []).count >= 2,"fetch did not include rotated files")
            // 5.7 ships mysqlbinlog. The minimal 8.4 server image does not;
            // acquire its physical files directly as an independent raw archive.
            let container=try f.h.compose(["ps","-q",f.profile.service(.source)]).text
            let external=f.output.appendingPathComponent("external-raw")
            if f.profile.sourceVersion == .mysql57 {
                _ = try f.h.compose(["exec","-T",f.profile.service(.source),"mkdir","/tmp/offline-raw"])
                _ = try f.h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",f.profile.service(.source),"mysqlbinlog","--no-defaults","--read-from-remote-server","--host=127.0.0.1","--user=root","--raw","--to-last-log","--result-file=/tmp/offline-raw/",begin.file])
                _ = try f.docker(["cp",container+":/tmp/offline-raw",external.path])
            } else {
                try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
                for file in fetched["files"] as! [[String:Any]] {
                    let name=file["name"] as! String
                    _ = try f.docker(["cp",container+":/var/lib/mysql/"+name,external.appendingPathComponent(name).path])
                }
            }
            _ = try f.docker(["cp",external.path,f.helper+":/evidence/external-raw"])
            source["host"]="127.0.0.1";source["port"]=1;source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
            source["stopAfterTransactions"]=2;f.config["source"]=source
            let partial=try invoke("offline-partial","replay",initialize:true)
            try require(partial["transactionsApplied"] as? Int == 2 && partial["lifecycle"] as? String == "STOPPED","offline partial stop differs")
            source.removeValue(forKey:"stopAfterTransactions");f.config["source"]=source
            let finished=try invoke("offline-resume","replay")
            try require(finished["appliedGTIDSet"] as? String == end.gtids && finished["transactionsApplied"] as? Int == 5,"offline checkpoint differs")
            _ = try compare("offline_poc")
            // Same baseline/workload, raw external input, fresh state and target.
            _ = try f.sql(.target,seed)
            f.config["archive"]=["directory":"/evidence/external-raw"]
            f.config["stateDirectory"]="/evidence/external-state"
            let raw=try invoke("offline-external","replay",initialize:true)
            try require(raw["appliedGTIDSet"] as? String == end.gtids && raw["transactionsApplied"] as? Int == 5,"external raw checkpoint differs")
            _ = try compare("offline_poc")
            f.config["supportBundle"]=["output":"/evidence/support.tar","maximumBytes":64*1024*1024]
            var target=f.config["target"] as! [String:Any];target["password"]="must-not-be-exported";target.removeValue(forKey:"passwordEnvironment");f.config["target"]=target
            let bundle=try invoke("offline-support","support-bundle")
            try require(bundle["containsCustomerData"] as? Bool == true,"support bundle sensitivity label missing")
            let tar=f.output.appendingPathComponent("support.tar")
            _ = try f.docker(["cp",f.helper+":/evidence/support.tar",tar.path])
            let names=try f.runner.run(["tar","-tf",tar.path]).text
            try require(names.contains("state.sqlite") && names.contains("relay.frames") && names.contains("archive/"),"support evidence missing")
            let config=try f.runner.run(["tar","-xOf",tar.path,"configuration.json"]).text
            try require(!config.contains("must-not-be-exported") && config.contains("<excluded>"),"support config credential leaked")
        }
    }
}
