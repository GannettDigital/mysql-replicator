import Foundation

/// Native observations precede changes to Swift's supported DDL contract.
public enum NativeDDLQualification {
    public static func run(root: URL) throws {
        for restricted in [false,true] { try runCase(root:root,restricted:restricted) }
    }
    private static func runCase(root: URL,restricted: Bool) throws {
        var config=NativeCase();config.transaction=false
        let h=NativeHarness(root:root,config:config,artifactCategory:"native-ddl-suite")
        try FileManager.default.createDirectory(at:h.output,withIntermediateDirectories:true)
        h.composeEnvironment=["FIXTURE_DISABLED_ENGINES":restricted ? "InnoDB" : ""]
        var report:[String:Any]=["result":"failed","restricted":restricted,"swift_apply":"not_exercised"]
        var started=false,failure:Error?
        func stage(_ message:String) {FileHandle.standardError.write(Data("Native DDL: \(message)\n".utf8))}
        let cases = QualificationReporter(output: h.output, log: stage)
        func attempt(_ service:String,_ sql:String) throws -> CommandResult {
            try h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",service,"mysql","--no-defaults","-uroot","--batch","--raw","--skip-column-names","-e",sql],checked:false)
        }
        do {
            stage("\(restricted ? "restricted" : "unrestricted") engines; evidence: \(h.output.path)")
            started=true
            _ = try h.compose(["up","-d","--build","--wait","--wait-timeout","300"],timeout:360,onOutput:{FileHandle.standardError.write($0)})
            for service in h.services {
                if service != "source" {
                    _ = try h.sql(service,"SET GLOBAL default_storage_engine=MyISAM")
                    if restricted {_ = try h.sql(service,"SET GLOBAL default_tmp_storage_engine=MyISAM")}
                }
                _ = try h.sql(service,"CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin")
                try h.sql(service,"SELECT VERSION(),@@default_storage_engine,@@default_tmp_storage_engine,@@disabled_storage_engines,@@sql_mode").write(to:h.output.appendingPathComponent(service+"-settings.tsv"),atomically:true,encoding:.utf8)
            }
            _ = try h.sql("source","CREATE USER 'ddl_reference'@'%' IDENTIFIED BY 'fixture-reference-only'; GRANT REPLICATION SLAVE ON *.* TO 'ddl_reference'@'%'")
            let start=try h.boundary("source")
            _ = try h.sql("native","SET @@GLOBAL.gtid_purged='+\(start.gtids)'; CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='ddl_reference',SOURCE_PASSWORD='fixture-reference-only',GET_SOURCE_PUBLIC_KEY=1,SOURCE_AUTO_POSITION=1; START REPLICA")
            var observations:[[String:Any]]=[]
            for (test,sql) in DDLCoverageCases.native {
                let name = test.id
                try cases.run(test) {
                    let source=try attempt("source",sql),direct=try attempt("target57",sql)
                    var item:[String:Any]=["case":name,"sql":sql,"source_status":source.status,"source_stderr":String(decoding:source.stderr,as:UTF8.self),"target57_status":direct.status,"target57_stderr":String(decoding:direct.stderr,as:UTF8.self)]
                    item.merge(test.fields) { _, new in new }
                    if source.status==0 {
                        let end=try h.boundary("source")
                        _ = try h.sql("native","SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),10)")
                        let status=try h.status();item["native_status"]=status
                        let nativeError=status["Last_SQL_Errno"] ?? "unknown"
                        if name=="explicit" && restricted {
                            try require(nativeError=="3161" && status["Replica_SQL_Running"]=="No" && String(decoding:direct.stderr,as:UTF8.self).contains("ERROR 3161"),"explicit InnoDB did not fail under engine restriction")
                            _ = try h.sql("source","CREATE TABLE poc.after_explicit(id INT PRIMARY KEY)")
                            try require(h.sql("native","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='after_explicit'")=="0","native applied following DDL after failure")
                        } else {try require(nativeError=="0","unexpected native DDL failure: \(nativeError)")}
                    } else {try require(name=="bare_default" && String(decoding:source.stderr,as:UTF8.self).contains("ERROR 1064") && String(decoding:direct.stderr,as:UTF8.self).contains("ERROR 1064"),"unexpected source rejection")}
                    let database=name=="owning_database" ? "otherdb" : "poc"
                    for service in h.services {
                        let metadata=try h.sql(service,"SELECT t.ENGINE,c.COLUMN_NAME,IFNULL(c.CHARACTER_SET_NAME,''),IFNULL(c.COLLATION_NAME,'') FROM information_schema.TABLES t JOIN information_schema.COLUMNS c USING(TABLE_SCHEMA,TABLE_NAME) WHERE t.TABLE_SCHEMA='\(database)' AND t.TABLE_NAME='\(name)' ORDER BY c.ORDINAL_POSITION")
                        item[service+"_schema"]=metadata
                        if name=="quoted_default" {try require(metadata.hasPrefix(service=="source" || !restricted ? "InnoDB" : "MyISAM"),"quoted DEFAULT engine differs")}
                        if name=="omitted" {try require(metadata.hasPrefix(service=="source" ? "InnoDB" : "MyISAM"),"omitted engine did not use local default")}
                        if name=="collate_only" {try require(metadata.contains("utf8mb4\tutf8mb4_bin"),"COLLATE-only lost charset association")}
                        if name=="explicit" {try require(service != "source" && restricted ? metadata.isEmpty : metadata.hasPrefix("InnoDB"),"explicit engine effects differ")}
                        if name=="owning_database" {try require(metadata.contains("latin1\tlatin1_bin"),"CREATE used wrong database default")}
                    }
                    observations.append(item);try writeJSON(observations,to:h.output.appendingPathComponent("matrix.json"))
                }
            }
            for service in h.services {
                _ = try h.sql(service,"FLUSH BINARY LOGS")
                let logs=try h.sql(service,"SHOW BINARY LOGS").split(separator:"\n").dropLast()
                for log in logs {
                    let name=String(log.split(separator:"\t")[0])
                    try require(name.range(of:#"^binlog\.[0-9]+$"#,options:.regularExpression) != nil,"unsafe log name")
                    let raw=try h.compose(["exec","-T",service,"cat","/var/lib/mysql/"+name]).stdout
                    let path=h.output.appendingPathComponent(service+"-"+name);try raw.write(to:path)
                    let decoded=try h.runner.run([h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv",path.path])
                    try decoded.stdout.write(to:path.appendingPathExtension("txt"))
                }
            }
            report["cases"]=observations;report["result"]="passed"
        } catch {failure=cases.fail(error);report["error"]=String(describing:failure!)}
        report["case_results"]=cases.results
        if started {
            if let logs=try? h.compose(["logs","--no-color"]) {try? (logs.stdout+logs.stderr).write(to:h.output.appendingPathComponent("containers.log"))}
            do {_ = try h.compose(["down","--volumes","--remove-orphans"]);report["cleanup"]="passed"}
            catch {report["cleanup"]=String(describing:error);if failure==nil {failure=error}}
        }
        report["result"]=failure==nil ? "passed" : "failed"
        try writeJSON(report,to:h.output.appendingPathComponent("result.json"))
        if let failure {throw failure}
    }
}
