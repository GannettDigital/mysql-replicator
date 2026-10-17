import Foundation

extension SharedCorrectness.Run {
    func jsonYearCompatibility() throws {
        guard f.profile == .reverse, selects("json-year-compatibility") else { return }
        try reporter.run(.init("json-year-compatibility","Explicit JSON YEAR conversion, strict refusal, restart and offline replay")) {
            try resetNativeEngine(); try f.awaitNative()
            let seed="SET sql_log_bin=0; DROP DATABASE IF EXISTS json_year; CREATE DATABASE json_year CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE json_year.t(id INT PRIMARY KEY,y YEAR,doc JSON,scalar JSON) ENGINE=InnoDB"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,seed) }
            let start=try f.boundary(), isolated=LabIsolatedApply(f), original=f.config
            defer { f.config=original }
            let initial=isolated.configuration("json-year-live",at:start,count:2)
            _ = try f.sql(.source,session+"INSERT INTO json_year.t VALUES(1,0,NULL,NULL),(2,1901,NULL,NULL),(3,2026,NULL,NULL),(4,2155,NULL,NULL); UPDATE json_year.t SET doc=JSON_OBJECT('nested',JSON_ARRAY(y),'plain',2026),scalar=JSON_EXTRACT(JSON_ARRAY(y),'$[0]')")
            try f.awaitNative()
            // The default path must stop before a write that loses the source type.
            var strict=initial; strict["stateDirectory"]="/evidence/json-year-strict"
            let rejected=try isolated.start("json-year-strict",config:strict)
            _ = try isolated.finish(rejected,label:"json-year-strict",config:strict,reason:"cannot preserve JSON type 13")
            try require(f.sql(.target,"SELECT COUNT(*) FROM json_year.t WHERE doc IS NULL AND scalar IS NULL") == "4","strict JSON refusal changed row data")
            try require(isolated.state("json-year-strict","SELECT transactions_applied FROM state") == "1","strict JSON refusal advanced checkpoint")
            _ = try f.sql(.target,seed)
            try isolated.resetTargetGTIDs(at:start)
            var config=initial
            config["compatibility"]=["jsonYearToInteger":true]
            func live(_ label:String,count:Int,initialize:Bool=false) throws -> [String:Any] {
                var source=config["source"] as! [String:Any]; source["stopAfterTransactions"]=count; config["source"]=source
                let client=try isolated.start(label,config:config,initialize:initialize)
                return try isolated.finish(client,label:label,config:config)
            }
            func verify(_ count:Int) throws {
                try f.awaitNative()
                let query="SELECT id,y,JSON_TYPE(JSON_EXTRACT(doc,'$.nested[0]')),JSON_TYPE(scalar),JSON_UNQUOTE(JSON_EXTRACT(doc,'$.nested[0]')),JSON_UNQUOTE(scalar) FROM json_year.t ORDER BY id"
                let source=try f.sql(.source,query), native=try f.sql(.native,query)
                try require(source == native,"native JSON YEAR bytes/type differ from source")
                try require(f.sql(.source,"SELECT COUNT(*) FROM json_year.t WHERE JSON_TYPE(scalar)='OPAQUE'") == String(count),"source did not retain opaque YEAR")
                // This target-side expression is an independent 8.4 constructor oracle.
                let check="SELECT COUNT(*) FROM json_year.t WHERE JSON_TYPE(scalar)='UNSIGNED INTEGER' AND JSON_TYPE(JSON_EXTRACT(doc,'$.nested[0]'))='UNSIGNED INTEGER' AND JSON_UNQUOTE(scalar)=CAST(CAST(y AS UNSIGNED) AS CHAR) AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.nested[0]'))=CAST(CAST(y AS UNSIGNED) AS CHAR) AND scalar=JSON_EXTRACT(JSON_ARRAY(y),'$[0]') AND JSON_EXTRACT(doc,'$.plain')=2026"
                try require(f.sql(.target,check) == String(count),"translated JSON YEAR value/type differs from native 8.4 construction")
                try require(f.sql(.target,"SELECT id,y FROM json_year.t ORDER BY id") == f.sql(.source,"SELECT id,y FROM json_year.t ORDER BY id"),"normal YEAR columns changed")
                try writeJSON(["source":source,"native":native,"target":try f.sql(.target,query)],to:f.output.appendingPathComponent("json-year-\(count)-rows.json"))
            }
            _ = try live("json-year-insert",count:2,initialize:true)
            try verify(4)
            var changed=config; changed["compatibility"]=["jsonYearToInteger":false]
            let wrong=try isolated.start("json-year-policy-change",config:changed,initialize:false)
            _ = try isolated.finish(wrong,label:"json-year-policy-change",config:changed,reason:"differs from saved state")
            // Restart with a changed primary key and full JSON before-images.
            _ = try f.sql(.source,session+"UPDATE json_year.t SET id=13,y=2155,doc=JSON_OBJECT('nested',JSON_ARRAY(y),'plain',2026),scalar=JSON_EXTRACT(JSON_ARRAY(y),'$[0]') WHERE id=3")
            _ = try live("json-year-update",count:1)
            try verify(4)
            _ = try f.sql(.source,session+"DELETE FROM json_year.t WHERE id IN (1,13)")
            let completed=try live("json-year-delete",count:1)
            try verify(2)
            let end=try f.boundary()
            try require(completed["appliedGTIDSet"] as? String == end.gtids && completed["transactionsApplied"] as? Int == 4,"JSON YEAR live checkpoint differs")
            f.config=config
            var source=config["source"] as! [String:Any]; source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source; f.config["archive"]=["directory":"/evidence/json-year-archive","firstFile":start.file]
            func invoke(_ label:String,_ command:String,initialize:Bool=false) throws -> [String:Any] {
                try f.installConfig(label)
                let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
                let exit=try f.runner.run(["docker","wait",client],timeout:120).text
                let logs=try f.docker(["logs",client]); try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(exit == "0","JSON YEAR command failed; inspect "+label+".ndjson and support bundle")
                let bytes=command == "replay" ? logs.stderr : logs.stdout
                guard let line=bytes.split(separator:10).last,let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing JSON YEAR command summary") }
                return result
            }
            _ = try invoke("json-year-fetch","fetch")
            _ = try f.sql(.target,seed)
            try isolated.resetTargetGTIDs(at:start)
            f.config["stateDirectory"]="/evidence/json-year-replay"
            source["host"]="127.0.0.1"; source["port"]=1
            source.removeValue(forKey:"passwordEnvironment"); source.removeValue(forKey:"password")
            source["stopAfterTransactions"]=2; f.config["source"]=source
            _ = try invoke("json-year-replay-insert","replay",initialize:true)
            try require(f.sql(.target,"SELECT COUNT(*) FROM json_year.t WHERE JSON_TYPE(scalar)='UNSIGNED INTEGER'") == "4","replayed JSON YEAR insert differs")
            source.removeValue(forKey:"stopAfterTransactions"); f.config["source"]=source
            let replay=try invoke("json-year-replay-resume","replay")
            try require(replay["appliedGTIDSet"] as? String == end.gtids && replay["transactionsApplied"] as? Int == 4,"JSON YEAR replay checkpoint differs")
            try verify(2)
        }
    }
}
