import Foundation

extension SharedCorrectness.Run {
    func largeValues() throws {
        guard selects("large-values") else { return }
        try reporter.run(QualificationCase("large-values","Large TEXT/BLOB writes, packet fragmentation, restart, replay and recovery")) {
            try resetNativeEngine(); try f.awaitNative()
            if f.profile.hasOptionalMetadata { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata) }
            let original=f.config
            defer { f.config=original }
            for role in LabProfile.Role.allCases {
                _ = try f.sql(role,"SET GLOBAL max_allowed_packet=67108864; SET sql_log_bin=0; DROP DATABASE IF EXISTS large_poc")
            }
            let start=try f.boundary(), isolated=LabIsolatedApply(f)
            var config=isolated.configuration("large-live",at:start,count:3)
            func source(_ sql:String) throws { _ = try f.sql(.source,session+sql) }
            func live(_ label:String, count:Int, initialize:Bool=false) throws -> [String:Any] {
                var source=config["source"] as! [String:Any]; source["stopAfterTransactions"]=count; config["source"]=source
                let client=try isolated.start(label,config:config,initialize:initialize)
                return try isolated.finish(client,label:label,config:config)
            }
            func compareValues(_ label:String, count:Int) throws {
                try f.awaitNative()
                let query="SELECT id,IFNULL(OCTET_LENGTH(b),-1),IFNULL(SHA2(b,256),'NULL'),IFNULL(OCTET_LENGTH(t),-1),IFNULL(SHA2(t,256),'NULL') FROM large_poc.t ORDER BY id"
                var values:[String:String]=[:]
                for role in LabProfile.Role.allCases {
                    try require(f.sql(role,"SELECT COUNT(*) FROM large_poc.t") == String(count),"large-value row count differs")
                    values[role.rawValue]=try f.sql(role,query)
                }
                try require(Set(values.values).count == 1,"large-value length or SHA-256 differs from native/source")
                try writeJSON(values,to:f.output.appendingPathComponent(label+"-digests.json"))
            }
            try source("CREATE DATABASE large_poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
            try source("CREATE TABLE large_poc.t(id INT PRIMARY KEY,b LONGBLOB,t LONGTEXT) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
            // Generate values on the source. The test client does not send a
            // large request. Capture and the external target must carry it.
            try source("INSERT INTO large_poc.t VALUES(1,REPEAT(0xA5,1048575),''),(2,REPEAT(0x00,1048576),NULL),(3,REPEAT(0xFF,1048577),REPEAT('é',524289)),(4,REPEAT(0xA5,17825795),'large')")
            _ = try live("large-insert",count:3,initialize:true)
            try compareValues("large-insert",count:4)
            try require(f.sql(.source,"SELECT OCTET_LENGTH(b) FROM large_poc.t WHERE id=4") == "17825795","source did not create the large value")
            // Each phase resumes the same SQLite state. UPDATE and DELETE must
            // read a fragmented target response before issuing their mutation.
            try source("UPDATE large_poc.t SET b=REPEAT(0x5A,17825795),t=REPEAT('é',524289) WHERE id=4")
            _ = try live("large-update",count:1)
            try compareValues("large-update",count:4)
            try source("DELETE FROM large_poc.t WHERE id IN (1,4)")
            _ = try live("large-delete",count:1)
            try compareValues("large-delete",count:2)
            let end=try f.boundary()

            f.config=config
            var sourceConfig=f.config["source"] as! [String:Any]
            sourceConfig.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=sourceConfig
            f.config["archive"]=["directory":"/evidence/large-archive","firstFile":start.file]
            func invoke(_ label:String,_ command:String,initialize:Bool=false) throws -> [String:Any] {
                try f.installConfig(label)
                let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
                let exit=try f.runner.run(["docker","wait",client],timeout:180).text
                let logs=try f.docker(["logs",client])
                try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(exit == "0","large-value command failed; inspect "+label+".ndjson and support bundle")
                let bytes=command == "replay" ? logs.stderr : logs.stdout
                guard let line=bytes.split(separator:10).last,let value=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing large-value command result") }
                return value
            }
            _ = try invoke("large-fetch","fetch")
            _ = try f.sql(.target,"SET sql_log_bin=0; DROP DATABASE large_poc")
            f.config["stateDirectory"]="/evidence/large-replay"
            sourceConfig["host"]="127.0.0.1"; sourceConfig["port"]=1
            sourceConfig.removeValue(forKey:"passwordEnvironment"); sourceConfig.removeValue(forKey:"password")
            sourceConfig["stopAfterTransactions"]=3; f.config["source"]=sourceConfig
            _ = try invoke("large-replay-partial","replay",initialize:true)
            try require(f.sql(.target,"SELECT OCTET_LENGTH(b) FROM large_poc.t WHERE id=4") == "17825795","large replay insert differs")
            sourceConfig.removeValue(forKey:"stopAfterTransactions"); f.config["source"]=sourceConfig
            let replay=try invoke("large-replay-resume","replay")
            try require(replay["appliedGTIDSet"] as? String == end.gtids,"large replay checkpoint differs")
            try compareValues("large-replay",count:2)

            // A valid event can exceed an explicitly smaller capture limit.
            // This refusal must leave the target unchanged and publish no GTID.
            let before=try f.boundary()
            try source("INSERT INTO large_poc.t VALUES(9,REPEAT(0xAB,17825795),'recovery')")
            var limited=isolated.configuration("large-event-limit",at:before,count:1)
            var limitSource=limited["source"] as! [String:Any]
            limitSource["maximumEventBytes"]=1048576; limited["source"]=limitSource
            let refused=try isolated.start("large-event-limit",config:limited)
            _ = try isolated.finish(refused,label:"large-event-limit",config:limited,success:false)
            try require(isolated.state("large-event-limit","SELECT transactions_applied FROM state") == "0","event limit advanced progress")
            try require(f.sql(.target,"SELECT COUNT(*) FROM large_poc.t WHERE id=9") == "0","event refusal wrote target")

            // An ordinary client uses target max_allowed_packet, even though
            // the native replica accepts this event with its replication limit.
            _ = try f.sql(.target,"SET GLOBAL max_allowed_packet=1048576")
            let recovery=isolated.configuration("large-recovery",at:before,count:1)
            let rejected=try isolated.start("large-target-limit",config:recovery)
            _ = try isolated.finish(rejected,label:"large-target-limit",config:recovery,reason:"max_allowed_packet")
            try require(f.sql(.target,"SELECT COUNT(*) FROM large_poc.t WHERE id=9") == "0","packet refusal wrote target")
            f.config=recovery; try f.installConfig()
            let report=try f.recovery(["inspect"],label:"large-recovery-inspection")
            guard let pending=report["pending"] as? [[String:Any]], pending.count == 1,
                  let rows=pending[0]["rows"] as? [[String:Any]], rows.count == 1,
                  let after=rows[0]["after"] as? [[String:Any]], after.count == 3,
                  let encoded=after[1]["value"] as? String,
                  Data(base64Encoded:encoded) == Data(repeating:0xAB,count:17825795) else { throw LabError("large recovery image differs") }
            _ = try f.sql(.target,"SET GLOBAL max_allowed_packet=67108864")
            let gtid=pending[0]["gtid"] as! String
            _ = try f.recovery(["resolve","retry","--gtids",gtid,"--reason","fixture confirmed request was not issued"],label:"large-recovery-resolution")
            config=recovery
            _ = try live("large-recovery-resume",count:1)
            try compareValues("large-recovery",count:3)
        }
    }
}
