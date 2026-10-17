import Foundation

extension SharedCorrectness.Run {
    func target84IndexSpatialMetadata() throws {
        guard f.profile == .reverse,selects("target84-index-spatial-metadata") else { return }
        try reporter.run(.init("target84-index-spatial-metadata","8.4 invisible indexes and SRID constraints survive DML, ALTER, restart and replay")) {
            try resetNativeEngine();try f.awaitNative()
            let base="SET sql_log_bin=0; DROP DATABASE IF EXISTS spatial_ddl; CREATE DATABASE spatial_ddl CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "
            let ordinary="CREATE TABLE spatial_ddl.t(id INT PRIMARY KEY,p POINT NOT NULL,n INT,KEY by_n(n)) ENGINE=InnoDB"
            let enhanced="CREATE TABLE spatial_ddl.t(id INT PRIMARY KEY,p POINT NOT NULL SRID 0,n INT,KEY by_n(n) INVISIBLE,SPATIAL KEY by_p(p)) ENGINE=InnoDB"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,base+(role == .target ? enhanced : ordinary)) }
            let start=try f.boundary(), isolated=LabIsolatedApply(f),original=f.config
            defer { f.config=original }
            let config=isolated.configuration("spatial-metadata-live",at:start,count:1)
            func apply(_ label:String,initialize:Bool=false) throws -> [String:Any] {
                let client=try isolated.start(label,config:config,initialize:initialize)
                return try isolated.finish(client,label:label,config:config)
            }
            func verify() throws {
                try f.awaitNative()
                let sql="SELECT id,HEX(p),n FROM spatial_ddl.t ORDER BY id"
                let expected=try f.sql(.source,sql)
                try require(f.sql(.native,sql) == expected && f.sql(.target,sql) == expected,"spatial rows differ from source/native")
                try require(f.sql(.target,"SELECT IS_VISIBLE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='spatial_ddl' AND TABLE_NAME='t' AND INDEX_NAME IN ('by_n','renamed')") == "NO","index visibility was lost")
                try require(f.sql(.target,"SELECT SRS_ID FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='spatial_ddl' AND TABLE_NAME='t' AND COLUMN_NAME='p'") == "0","SRID constraint was lost")
            }
            _ = try f.sql(.source,session+"INSERT INTO spatial_ddl.t VALUES(1,ST_GeomFromText('POINT(10 20)',0),10),(2,ST_GeomFromText('POINT(30 40)',0),20)")
            _ = try apply("spatial-metadata-insert",initialize:true);try verify()
            _ = try f.sql(.source,session+"ALTER TABLE spatial_ddl.t RENAME INDEX by_n TO renamed,ADD extra INT DEFAULT 7")
            _ = try apply("spatial-metadata-alter");try verify()
            _ = try f.sql(.source,session+"UPDATE spatial_ddl.t SET p=ST_GeomFromText('POINT(50 60)',0),n=30 WHERE id=1")
            _ = try apply("spatial-metadata-update");try verify()
            _ = try f.sql(.source,session+"DELETE FROM spatial_ddl.t WHERE id=2")
            let completed=try apply("spatial-metadata-delete");try verify()
            let end=try f.boundary()
            try require(completed["appliedGTIDSet"] as? String == end.gtids,"Spatial metadata live checkpoint differs")
            // Reset only the target. Replay must discover the same target-only
            // metadata and retain it across a saved-state restart.
            f.config=config
            var source=config["source"] as! [String:Any];source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source;f.config["archive"]=["directory":"/evidence/spatial-metadata-archive","firstFile":start.file]
            func invoke(_ label:String,_ command:String,initialize:Bool=false) throws -> [String:Any] {
                try f.installConfig(label)
                let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
                let exit=try f.runner.run(["docker","wait",client],timeout:120).text
                let logs=try f.docker(["logs",client]);try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(exit == "0","Spatial metadata command failed; inspect "+label+".ndjson and support bundle")
                let bytes=command == "replay" ? logs.stderr : logs.stdout
                guard let line=bytes.split(separator:10).last,let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing Spatial metadata summary") }
                return result
            }
            _ = try invoke("spatial-metadata-fetch","fetch")
            _ = try f.sql(.target,base+enhanced)
            f.config["stateDirectory"]="/evidence/spatial-metadata-replay"
            source["host"]="127.0.0.1";source["port"]=1;source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
            source["stopAfterTransactions"]=1;f.config["source"]=source
            _ = try invoke("spatial-metadata-replay-insert","replay",initialize:true)
            source.removeValue(forKey:"stopAfterTransactions");f.config["source"]=source
            let replay=try invoke("spatial-metadata-replay-resume","replay")
            try require(replay["appliedGTIDSet"] as? String == end.gtids && replay["transactionsApplied"] as? Int == 4,"Spatial metadata replay checkpoint differs")
            try verify()
            let saved=try isolated.state("spatial-metadata-delete","SELECT schema_json FROM schemas WHERE current=1")
            try require(saved.contains("spatialReferenceID") && saved.contains("visible"),"durable schema lost target-only metadata")
        }
    }
}
