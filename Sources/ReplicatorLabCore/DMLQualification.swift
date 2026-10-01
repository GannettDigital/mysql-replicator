import Foundation

public enum DMLQualification {
    public static func run(root: URL, build: Bool = true, ddl: Bool = false) throws {
        let runner = ProcessRunner(root:root)
        let image = "mysql-replicator-packaging:dml"
        let coverageInputs = ddl ? try DDLCoverageEvidence.inputs(root: root) : nil
        let coverageContracts = ddl ? try DDLCoverageEvidence.hashes(root: root, paths: DDLCoverageEvidence.contractPaths) : nil
        let labels = try coverageInputs.map { ["--label", DDLCoverageEvidence.imageLabel + "=" + (try DDLCoverageEvidence.digest($0))] } ?? []
        if build {
            FileHandle.standardError.write(Data("\(ddl ? "DDL" : "DML") suite: building static Ubuntu image (live build output follows).\n".utf8))
            let result = try runner.run(["docker","build","--progress=plain","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",image] + labels + ["."],timeout:3600,checked:false,onOutput:{ FileHandle.standardError.write($0) })
            let log = root.appendingPathComponent("artifacts/dml-suite/build-" + runID() + ".log")
            try FileManager.default.createDirectory(at:log.deletingLastPathComponent(),withIntermediateDirectories:true)
            try (result.stdout + result.stderr).write(to:log)
            try require(result.status == 0,"DML image build failed; see \(log.path)")
        }
        let qualifiedImage = try runner.run(["docker","image","inspect",image,"--format","{{.Id}}"]).text
        for mode in ["file-position","gtid"] { try runCase(root:root,image:qualifiedImage,mode:mode,ddl:ddl,coverageInputs:coverageInputs,coverageContracts:coverageContracts) }
    }
    private static func runCase(root: URL,image: String,mode: String,ddl: Bool,coverageInputs: [String: String]?,coverageContracts: [String: String]?) throws {
        var native = NativeCase(); native.transaction = false; native.autoPosition = mode == "gtid"
        let h = NativeHarness(root:root,config:native,artifactCategory:ddl ? "ddl-suite" : "dml-suite")
        let runner = h.runner, output = h.output, tls = output.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at:tls,withIntermediateDirectories:true)
        h.composeOverlays = [root.appendingPathComponent("docker/dml/compose.yaml").path]
        let evidenceVolume = h.project + "-evidence", evidenceHelper = h.project + "-evidence-copy"
        h.composeEnvironment = ["REPLICATOR_DML_EVIDENCE_VOLUME":evidenceVolume]
        var volumeCreated = false, helperCreated = false
        var copiedStates: Set<String> = []
        var clients: [String] = [], started = false, failure: Error?
        var report: [String:Any] = ["schema_version":1,"result":"failed","mode":mode,"automatic_recovery":false,"ddl":ddl ? "qualified_subset" : "not_exercised"]
        func stage(_ text: String) { FileHandle.standardError.write(Data(("\(ddl ? "DDL" : "DML") \(mode): " + text + "\n").utf8)) }
        let cases = QualificationReporter(output: output, log: stage)
        let coverageProfile = mode == "gtid" ? "swift.gtid.metadata-full" : "swift.position.metadata-minimal"
        var coverageRuntime: [String: Any] = [:]
        stage("evidence: \(output.path)")
        func docker(_ args: [String]) throws -> CommandResult { try runner.run(["docker"] + args) }
        func record(_ name: String,_ args: [String]) throws -> CommandResult {
            let r = try runner.run(args,checked:false)
            try r.stdout.write(to:output.appendingPathComponent(name + ".stdout")); try r.stderr.write(to:output.appendingPathComponent(name + ".stderr"))
            try require(r.status == 0,"\(name) failed; see evidence")
            return r
        }
        func start(_ test: QualificationCase,_ config: [String:Any]) throws -> String {
            try cases.begin(test)
            let label = test.id
            try writeJSON(config,to:output.appendingPathComponent(label + ".json"))
            _ = try docker(["cp",output.appendingPathComponent(label + ".json").path,evidenceHelper + ":/evidence/" + label + ".json"])
            let name = h.project + "-" + label; clients.append(name)
            _ = try docker(["run","-d","--name",name,"--platform","linux/amd64","--network",h.project + "_fixture",
                "--mount","type=volume,src=\(evidenceVolume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only",
                "--entrypoint","/usr/local/bin/mysql-replicator",image,"run","--config","/evidence/\(label).json","--initialize"])
            return name
        }
        func finish(_ name: String,_ label: String,success: Bool,reason: String? = nil) throws -> [String:Any] {
            let exit = try runner.run(["docker","wait",name],timeout:45).text
            let logs = try docker(["logs",name])
            try logs.stdout.write(to:output.appendingPathComponent(label + ".ndjson")); try logs.stderr.write(to:output.appendingPathComponent(label + ".diagnostic.json"))
            try require(success ? exit == "0" : exit != "0","\(label) unexpected exit \(exit); see diagnostic")
            let lines = String(decoding:logs.stderr,as:UTF8.self).split(separator:"\n")
            guard let last = lines.last,let object = try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any] else { throw LabError("missing \(label) diagnostic") }
            if let reason { try require((object["reason"] as? String ?? "").contains(reason),"\(label) failed for the wrong reason") }
            return object
        }
        func waitForReader(_ name: String) throws {
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                if try h.sql("source","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'") == "1" { return }
                let running = try docker(["inspect",name,"--format","{{.State.Running}}"]).text
                if running != "true" { let logs = try docker(["logs",name]); throw LabError("applier stopped before capture: " + String(decoding:logs.stderr,as:UTF8.self)) }
                Thread.sleep(forTimeInterval:0.2)
            }
            throw LabError("applier did not start capture")
        }
        func state(_ label: String,_ sql: String) throws -> String {
            // Called only after the writer exits. Never share live SQLite WAL
            // files or locks between the host and Docker's VM.
            if copiedStates.insert(label).inserted {
                _ = try docker(["cp",evidenceHelper + ":/evidence/state-" + label,output.path])
            }
            return try runner.run(["sqlite3",output.appendingPathComponent("state-" + label + "/state.sqlite").path,sql]).text
        }
        do {
            report["image"] = try docker(["image","inspect",image,"--format","{{.Id}}"]).text
            let version = try runner.run([h.decoder,"--no-defaults","--version"]).text
            try require(version.contains("Ver 8.4."),"MySQL 8.4 mysqlbinlog required"); report["reference_decoder"] = version
            _ = try record("ca", ["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","2","-subj","/CN=Replicator Live Test CA","-keyout",tls.appendingPathComponent("ca-key.pem").path,"-out",tls.appendingPathComponent("ca.pem").path])
            _ = try record("csr", ["openssl","req","-newkey","rsa:2048","-nodes","-sha256","-subj","/CN=source","-keyout",tls.appendingPathComponent("server-key.pem").path,"-out",tls.appendingPathComponent("server.csr").path])
            let ext = tls.appendingPathComponent("extensions.cnf")
            try "subjectAltName=DNS:source,DNS:target57\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to:ext,atomically:true,encoding:.utf8)
            _ = try record("certificate", ["openssl","x509","-req","-in",tls.appendingPathComponent("server.csr").path,"-CA",tls.appendingPathComponent("ca.pem").path,"-CAkey",tls.appendingPathComponent("ca-key.pem").path,"-CAcreateserial","-days","2","-sha256","-extfile",ext.path,"-out",tls.appendingPathComponent("server.pem").path])
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:tls.appendingPathComponent("server-key.pem").path)
            stage("staging TLS in a Docker volume")
            _ = try docker(["volume","create",evidenceVolume]); volumeCreated = true
            _ = try docker(["create","--name",evidenceHelper,"--platform","linux/amd64","--mount","type=volume,src=\(evidenceVolume),dst=/evidence","--entrypoint","/bin/true",image]); helperCreated = true
            _ = try docker(["cp",tls.path,evidenceHelper + ":/evidence/tls"])
            stage("starting three MySQL servers (live Compose output follows)")
            started = true
            let startup = try h.compose(["up","-d","--build","--wait","--wait-timeout","300"],timeout:360,onOutput:{ FileHandle.standardError.write($0) })
            try (startup.stdout + startup.stderr).write(to:output.appendingPathComponent("startup.log"))
            let targetContainer = try h.compose(["ps","-q","target57"]).text
            let targetCommand = try docker(["inspect",targetContainer,"--format","{{json .Config.Cmd}}"]).stdout
            let command = try JSONSerialization.jsonObject(with:targetCommand) as? [String]
            try require(command?.contains("--skip-slave-start") == true,"fixture must disable native auto-start")
            report["native_auto_start"] = "disabled_by_verified_container_startup_argument"
            _ = try h.sql("source","CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'capture_fixture'@'%'; CREATE USER 'native_fixture'@'%' IDENTIFIED BY 'fixture-native-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'native_fixture'@'%'")
            for service in h.services {
                if ddl && service != "source" {_ = try h.sql(service,"SET GLOBAL default_storage_engine=MyISAM; SET GLOBAL default_tmp_storage_engine=MyISAM")}
                if ddl {_ = try h.sql(service,"CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin")}
                let engine = service == "source" ? "InnoDB" : "MyISAM"
                _ = try h.sql(service,"CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(engine); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)")
            }
            _ = try h.sql("target57","CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP ON poc.* TO 'apply_fixture'@'%'; GRANT REPLICATION CLIENT,SUPER ON *.* TO 'apply_fixture'@'%'; GRANT SELECT ON performance_schema.* TO 'apply_fixture'@'%'")
            if ddl {_ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP ON otherdb.* TO 'apply_fixture'@'%'")}
            if ddl {
                for database in Set(DatabaseCreationCases.cases.map(\.database)) {
                    _ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP ON \(database).* TO 'apply_fixture'@'%'")
                }
            }
            if mode == "gtid" { _ = try h.sql("source","SET GLOBAL binlog_row_metadata=FULL") }
            if let coverageInputs {
                coverageRuntime = try DDLCoverageEvidence.runtime(h, image: image, profileID: coverageProfile,
                    inventory: DDLCoverage.load(directory: root.appendingPathComponent("tests/DDLCoverage")), inputDigest: DDLCoverageEvidence.digest(coverageInputs))
            }
            let uuid = try h.sql("source","SELECT @@server_uuid"), targetUUID = try h.sql("target57","SELECT @@server_uuid")
            let sourceStart = try h.boundary("source"), nativeStart = try h.boundary("native"), targetStart = try h.boundary("target57")
            let clause: String
            if mode == "gtid" { _ = try h.sql("native","SET @@GLOBAL.gtid_purged='+\(sourceStart.gtids)'"); clause = "SOURCE_AUTO_POSITION=1" }
            else { clause = "SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(sourceStart.file)',SOURCE_LOG_POS=\(sourceStart.position)" }
            _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='native_fixture',SOURCE_PASSWORD='fixture-native-only',SOURCE_SSL=1,\(clause); START REPLICA")
            func configuration(_ label: String,at boundary: Boundary,count: Int) -> [String:Any] {
                var start: [String:Any] = ["executedGTIDs":boundary.gtids]
                if mode == "file-position" { start["file"] = boundary.file; start["position"] = boundary.position }
                let source: [String:Any] = ["version":2,"host":"source","port":3306,"username":"capture_fixture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem","serverID":9100,"sourceUUID":uuid,"mode":mode,"start":start,"stopAfterTransactions":count]
                return ["version":2,"source":source,"target":["host":"target57","port":3306,"username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","serverHostname":"target57","caFile":"/evidence/tls/ca.pem","nativeAutoStartDisabled":true],"stateDirectory":"/evidence/state-" + label]
            }
            let positiveConfig = configuration("positive",at:sourceStart,count:4)
            let client = try start(DDLCoverageCases.positive,positiveConfig); try waitForReader(client)
            stage("running INSERT/UPDATE/DELETE workload")
            _ = try h.sql("source",Fixture.sql(transaction:false))
            let sourceEnd = try h.boundary("source")
            let positive = try finish(client,"positive",success:true)
            try require(positive["transactionsApplied"] as? Int == 4 && positive["rowsApplied"] as? Int == 4,"wrong applied counters")
            let reached = try h.sql("native","SELECT SOURCE_POS_WAIT('\(sourceEnd.file)',\(sourceEnd.position),30)")
            try require(reached != "NULL" && reached != "-1","native did not converge")
            for service in h.services { try require(h.rows(service) == Fixture.final,"\(service) rows differ") }
            try require(h.sql("target57","SELECT @@GLOBAL.gtid_executed").isEmpty,"Swift injected source GTIDs into target")
            try require(state("positive","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||applied_position||'|'||(SELECT gtids FROM snapshots ORDER BY id DESC LIMIT 1) FROM state") == "STOPPED|4|4|\(sourceEnd.position)|\(sourceEnd.gtids)","SQLite applied checkpoint differs")
            try require(state("positive","SELECT COUNT(*) FROM row_intents WHERE status='DONE'") == "4","missing completed row intents")
            _ = try h.sql("native","STOP REPLICA")
            let nativeEnd = try h.boundary("native"), targetEnd = try h.boundary("target57")
            for (service,from,to) in [("source",sourceStart,sourceEnd),("native",nativeStart,nativeEnd),("target57",targetStart,targetEnd)] {
                try Comparison.operations(h.capture(service,start:from,end:to),expected:Fixture.operations)
                let dir = output.appendingPathComponent(service)
                try FileManager.default.copyItem(at:dir.appendingPathComponent("operations.json"),to:dir.appendingPathComponent("positive-operations.json"))
            }
            try require(state("positive","SELECT target_uuid FROM state") == targetUUID,"discovered target UUID was not persisted")
            try cases.pass("positive")
            report["positive"] = positive
            if ddl {
                // Database creation has a separate durable stream per named
                // case; databases are deliberately absent from fixture setup.
                for test in DatabaseCreationCases.cases {
                    let label=test.test.id,boundary=try h.boundary("source")
                    let applying=try start(test.test,configuration(label,at:boundary,count:test.existing ? 4 : 5));try waitForReader(applying)
                    _ = try h.sql("native","START REPLICA")
                    let warnings=try h.sql("source",test.prefix+test.sql+"; SHOW WARNINGS")
                    try require(test.existing ? warnings.hasPrefix("Note\t1007\t") : warnings.isEmpty,"database CREATE warning differs: \(warnings)")
                    let table=test.database+".probe"
                    let prepare=test.existing ? "" : "CREATE TABLE \(table)(id INT PRIMARY KEY,note VARCHAR(20)); "
                    let insert=test.existing ? "INSERT INTO \(table) VALUES(2,NULL)" : "INSERT INTO \(table) VALUES(1,'seed'),(2,NULL)"
                    _ = try h.sql("source",prepare+insert+"; UPDATE \(table) SET id=3,note=CONVERT(0xF09F9880 USING utf8mb4) WHERE id=2; DELETE FROM \(table) WHERE id=3")
                    let end=try h.boundary("source")
                    let result=try finish(applying,label,success:true)
                    let wait=try h.sql("native","SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),20)")
                    try require(wait != "NULL" && wait != "-1" && h.status()["Last_SQL_Errno"]=="0","native database workload did not converge")
                    try require(result["appliedGTIDSet"] as? String==end.gtids && result["ddlApplied"] as? Int==(test.existing ? 1 : 2),"database checkpoint/DDL counters differ")
                    try require(state(label,"SELECT COUNT(*) FROM ddl_intents WHERE database_json IS NOT NULL AND before_schema_id IS NULL AND after_schema_id IS NULL AND status='DONE'")=="1","database intent invented a table schema or did not finish")
                    try require(state(label,"SELECT target_sql FROM ddl_intents WHERE database_json IS NOT NULL")==test.sql,"database CREATE SQL was rewritten")
                    try cases.assertion("schema-effects",evidence:"assertions/"+label+"/schema-effects.json") {
                        var observations:[String:Any]=["sql":test.sql,"source_warnings":warnings,"source_boundary":end.json]
                        for service in h.services {
                            let metadata=try h.sql(service,test.metadataSQL)
                            let columns=try h.sql(service,"SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,COLUMN_KEY,IFNULL(COLLATION_NAME,'') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe' ORDER BY ORDINAL_POSITION")
                            let engine=try h.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe'")
                            try require(metadata==test.expected && columns=="id\tint\tNO\tPRI\t\nnote\tvarchar\tYES\t\t"+test.collation,"database/table default inheritance differs: \(metadata), \(columns)")
                            try require(engine==(service=="source" ? "InnoDB" : "MyISAM"),"database workload changed local engine selection")
                            observations[service]=["database":metadata,"columns":columns,"engine":engine]
                        }
                        return observations
                    }
                    try cases.assertion("following-dml",evidence:"assertions/"+label+"/following-dml.json") {
                        try require(result["rowsApplied"] as? Int==(test.existing ? 3 : 4),"database following-DML row count differs")
                        var rows:[String:String]=[:]
                        for service in h.services {
                            rows[service]=try h.sql(service,"SELECT id,HEX(note) FROM \(table) ORDER BY id")
                            try require(rows[service]=="1\t73656564","database creation lost existing or following data")
                        }
                        return rows
                    }
                    _ = try h.sql("native","STOP REPLICA")
                    try cases.pass(label)
                }
                for (test,sql,prefix,reason) in [
                    (DatabaseCreationCases.unsupported,"CREATE DATABASE created_bad COLLATE utf8mb4_0900_ai_ci","","no substitution"),
                    (DatabaseCreationCases.unsupportedDefault,"CREATE DATABASE created_bad_default","SET SESSION collation_server=utf8mb4_0900_ai_ci; ","unsupported source server collation"),
                    (DatabaseCreationCases.denied,"CREATE DATABASE created_denied COLLATE utf8mb4_bin","","target SQL error")
                ] {
                    let label=test.id,boundary=try h.boundary("source")
                    let rejected=try start(test,configuration(label,at:boundary,count:2));try waitForReader(rejected)
                    _ = try h.sql("native","START REPLICA")
                    _ = try h.sql("source",prefix+sql+"; CREATE TABLE poc.after_"+label.replacingOccurrences(of:"-",with:"_")+"(id INT PRIMARY KEY)")
                    _ = try finish(rejected,label,success:false,reason:reason)
                    let end=try h.boundary("source")
                    let wait=try h.sql("native","SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),20)")
                    try require(wait != "NULL" && wait != "-1" && h.status()["Last_SQL_Errno"]=="0","native 8.4 failed a supported database definition")
                    try require(state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||COALESCE(applied_position,'NULL') FROM state")=="BLOCKED|0|NULL","failed database CREATE advanced checkpoint")
                    let pending=test.id==DatabaseCreationCases.denied.id ? "1" : "0"
                    try require(state(label,"SELECT COUNT(*) FROM ddl_intents WHERE database_json IS NOT NULL AND status='PENDING'")==pending,"database failure lost or invented a pending intent")
                    let database=sql.split(separator:" ")[2]
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(database)'")=="0","rejected database was created")
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='after_"+label.replacingOccurrences(of:"-",with:"_")+"'")=="0","database failure did not block following DDL")
                    _ = try h.sql("native","STOP REPLICA")
                    try cases.pass(label)
                }
                // Named scenarios retain their definition locations in progress and evidence.
                let changes = DDLCoverageCases.changes
                let ddlStart=try h.boundary("source"),ddlNativeStart=try h.boundary("native"),ddlTargetStart=try h.boundary("target57")
                let applying=try start(DDLCoverageCases.group,configuration("ddl",at:ddlStart,count:changes.count));try waitForReader(applying)
                _ = try h.sql("native","START REPLICA")
                for (index,change) in changes.enumerated() {
                    try cases.run(change.test) {
                        let prefix=change.table=="defaults" ? "SET SESSION default_collation_for_utf8mb4=utf8mb4_general_ci; " : ""
                        let assertionID = DDLCoverageCases.assertion(for: change.test.id)
                        let warnings = try h.sql("source",prefix+change.sql + (assertionID == nil ? "" : "; SHOW WARNINGS"))
                        let deadline=Date().addingTimeInterval(20)
                        var applied=0
                        repeat {
                            let logs=try docker(["logs",applying]).stdout
                            if let last=String(decoding:logs,as:UTF8.self).split(separator:"\n").last,
                               let value=try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any] {applied=value["transactionsApplied"] as? Int ?? 0}
                            if applied==index+1 {break}
                            if try docker(["inspect",applying,"--format","{{.State.Running}}"]).text != "true" {
                                let stopped=try docker(["logs",applying])
                                throw LabError("applier stopped before the expected transaction count: " + String(decoding:stopped.stderr,as:UTF8.self))
                            }
                            Thread.sleep(forTimeInterval:0.1)
                        } while Date()<deadline
                        try require(applied==index+1,"applier did not reach the expected transaction count")
                        let boundary=try h.boundary("source")
                        let reached=try h.sql("native","SELECT SOURCE_POS_WAIT('\(boundary.file)',\(boundary.position),20)")
                        try require(reached != "NULL" && reached != "-1","native DDL did not reach barrier")
                        func checkSchemaAndRows() throws -> Any {
                            var observations: [String: Any] = ["sql": change.sql, "source_warnings": warnings, "source_boundary": boundary.json]
                            if assertionID != nil {
                                let codes=try warnings.split(separator:"\n").map { line -> Int in
                                    let fields=line.split(separator:"\t")
                                    guard fields.count>=2,let code=Int(fields[1]) else {throw LabError("malformed source warning: \(line)")}
                                    return code
                                }
                                try require(codes==change.warnings,"unexpected source warnings: \(warnings)")
                            }
                            for service in h.services {
                                let schema=try h.sql(service,"SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME,':',DATA_TYPE,':',IS_NULLABLE) ORDER BY ORDINAL_POSITION) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                                try require(schema == (change.schema.isEmpty ? "NULL" : change.schema),"\(service) schema differs")
                                if !change.schema.isEmpty {
                                    let engine=try h.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                                    try require(engine == (service == "source" ? "InnoDB" : "MyISAM"),"DDL local engine selection differs")
                                    if change.schema.contains("note:") {
                                        let collation=try h.sql(service,"SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)' AND COLUMN_NAME='note'")
                                        try require(collation == change.collation,"DDL collation differs")
                                    }
                                    let fields=change.schema.contains("b:varbinary") ? "id,IFNULL(HEX(b),'NULL')" : change.schema.contains("note:") ? "id,IFNULL(HEX(note),'NULL')"+(change.schema.contains("payload:") ? ",IFNULL(HEX(payload),'NULL')" : "") : "id,IFNULL(HEX(payload),'NULL')"
                                    let rows=try h.sql(service,"SELECT \(fields) FROM \(change.database).\(change.table) ORDER BY id",preserveWhitespace:true)
                                    try require(rows == change.rows,"\(service) rows differ")
                                    try rows.write(to:output.appendingPathComponent("\(service)-ddl-\(change.test.id).tsv"),atomically:true,encoding:.utf8)
                                }
                                if assertionID != nil {
                                    let columns = try h.sql(service,"SELECT CONCAT(COLUMN_NAME,':',IF(DATA_TYPE IN ('int','bigint'),CONCAT(DATA_TYPE,IF(COLUMN_TYPE LIKE '%unsigned%',' unsigned','')),COLUMN_TYPE),':',IS_NULLABLE,':',IFNULL(COLUMN_DEFAULT,'<NULL>'),':',COLUMN_KEY,':',EXTRA,':',IFNULL(CHARACTER_SET_NAME,''),':',IFNULL(COLLATION_NAME,'')) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)' ORDER BY ORDINAL_POSITION")
                                    let expected = change.exactColumns
                                    try require(columns == expected, "\(service) exact column/default/key metadata differs: \(columns)")
                                    let defaults = try h.sql(service,"SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                                    try require(defaults == (change.schema.isEmpty ? "" : "utf8mb4_unicode_ci"), "\(service) table default collation differs")
                                    observations[service] = ["columns": columns, "table_collation": defaults, "schema": schema, "expected_rows": change.rows,
                                        "observed_rows": change.schema.isEmpty ? "" : try String(contentsOf: output.appendingPathComponent("\(service)-ddl-\(change.test.id).tsv"), encoding: .utf8),
                                        "engine": try h.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")]
                                }
                                if change.test.id=="rename-table" {try require(h.sql(service,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='changes'") == "0","renamed table remains")}
                            }
                            return observations
                        }
                        if let assertionID {
                            try cases.assertion(assertionID, evidence: "assertions/" + change.test.id + "/" + assertionID + ".json", checkSchemaAndRows)
                        } else { _ = try checkSchemaAndRows() }
                    }
                }
                let ddlEnd=try h.boundary("source")
                let ddlResult=try finish(applying,"ddl",success:true)
                try require(ddlResult["appliedGTIDSet"] as? String == ddlEnd.gtids,"DDL applied GTID coverage differs")
                let ddlCount=changes.filter{!$0.isDML}.count,rowCount=changes.filter{$0.isDML}.reduce(0){$0+$1.affectedRows}
                try require(ddlResult["ddlApplied"] as? Int == ddlCount && ddlResult["rowsApplied"] as? Int == rowCount,"DDL counters differ")
                try require(state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE status='DONE'") == String(ddlCount),"DDL intent history missing")
                try require(state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE target_sql LIKE 'CREATE TABLE IF NOT EXISTS%' AND before_schema_id IS NOT NULL AND before_schema_id=after_schema_id") == "3","conditional CREATE retired an unchanged schema")
                try require(state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE target_sql LIKE 'DROP TABLE IF EXISTS%' AND before_schema_id IS NULL AND after_schema_id IS NULL AND status='DONE'") == "1","absent DROP did not complete its no-op intent")
                let expectedCreates=changes.filter{$0.sql.hasPrefix("CREATE TABLE")}.map{$0.sql}.joined(separator:"\n")
                try require(state("ddl","SELECT target_sql FROM ddl_intents WHERE target_sql LIKE 'CREATE TABLE%' ORDER BY rowid")==expectedCreates,"CREATE SQL was rewritten")
                try require(state("ddl","SELECT COUNT(*) FROM schemas WHERE current=1") == "0","dropped schema remains current")
                try require(state("ddl","SELECT COUNT(*) FROM row_intents r LEFT JOIN schemas s ON s.id=r.schema_id WHERE s.id IS NULL") == "0","row intent lost historical schema")
                _ = try h.sql("native","STOP REPLICA")
                // Both replicas must select MyISAM through their local defaults.
                // Source DDL is retained unchanged; no engine/collation rewriting.
                for (service,from) in [("source",ddlStart),("native",ddlNativeStart),("target57",ddlTargetStart)] {
                    let end=try h.boundary(service)
                    _ = try h.capture(service,start:nil,end:nil)
                    let file=output.appendingPathComponent(service+"/"+from.file)
                    try require(from.file==end.file,"unexpected DDL binlog rotation")
                    let decoded=try runner.run([h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv","--start-position=\(from.position)","--stop-position=\(end.position)",file.path])
                    try decoded.stdout.write(to:output.appendingPathComponent(service+"-ddl-binlog.txt"))
                    let text=String(decoding:decoded.stdout,as:UTF8.self).uppercased()
                    let expectedKinds=changes.flatMap {Array(repeating:String($0.sql.split(separator:" ")[0]),count:$0.isDML ? $0.affectedRows : 1)}
                    let kinds=text.split(separator:"\n").compactMap {line -> String? in
                        for verb in ["CREATE TABLE","ALTER TABLE","RENAME TABLE","DROP TABLE","TRUNCATE TABLE"] {
                            if line.hasPrefix(verb+" ") {return String(verb.split(separator:" ")[0])}
                        }
                        for verb in ["INSERT INTO","UPDATE","DELETE FROM"] {
                            if line.hasPrefix("### "+verb+" ") {return String(verb.split(separator:" ")[0])}
                        }
                        return nil
                    }
                    try require(kinds==expectedKinds,"DDL/DML binlog operations differ in count or source order")
                    try writeJSON(kinds,to:output.appendingPathComponent(service+"-ddl-operation-kinds.json"))
                }
                try cases.pass("ddl")
                // Source accepts this statement, but both replicas lack its
                // externally prepared template. Qualify an actual apply failure.
                _ = try h.sql("source","SET SESSION sql_log_bin=0; CREATE TABLE poc.only_source(id INT PRIMARY KEY)")
                let missingStart=try h.boundary("source")
                let missing=try start(DDLCoverageCases.missingTemplate,configuration("ddl-like-missing-template",at:missingStart,count:2));try waitForReader(missing)
                _ = try h.sql("native","START REPLICA")
                _ = try h.sql("source","CREATE TABLE poc.failed_like LIKE poc.only_source; CREATE TABLE poc.after_failed_like(id INT PRIMARY KEY)")
                _ = try finish(missing,"ddl-like-missing-template",success:false,reason:"single primary-key")
                let failureDeadline=Date().addingTimeInterval(20)
                var nativeFailure=try h.status()
                while nativeFailure["Last_SQL_Errno"] == "0" && Date()<failureDeadline {
                    Thread.sleep(forTimeInterval:0.2);nativeFailure=try h.status()
                }
                try require(nativeFailure["Last_SQL_Errno"] == "1146" && nativeFailure["Replica_SQL_Running"] == "No","native did not stop on missing LIKE template")
                try require(state("ddl-like-missing-template","SELECT lifecycle||'|'||transactions_applied||'|'||COALESCE(applied_position,'NULL') FROM state") == "BLOCKED|0|NULL","missing LIKE template advanced checkpoint")
                for service in ["native","target57"] {
                    try require(h.sql(service,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME IN ('failed_like','after_failed_like')") == "0","replica applied failed LIKE or following DDL")
                }
                try writeJSON(nativeFailure,to:output.appendingPathComponent("native-like-missing-template-status.json"))
                _ = try h.sql("native","STOP REPLICA")
                try cases.pass(DDLCoverageCases.missingTemplate.id)
                for (test,sql,reason) in DDLCoverageCases.rejections {
                    let label = test.id
                    let rejected=try start(test,configuration(label,at:try h.boundary("source"),count:2));try waitForReader(rejected)
                    _ = try h.sql("source",sql+"; CREATE TABLE poc.after_\(label)(id INT PRIMARY KEY)")
                    _ = try finish(rejected,label,success:false,reason:reason)
                    try require(state(label,"SELECT lifecycle||'|'||transactions_applied FROM state")=="BLOCKED|0","DDL rejection advanced progress")
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME IN ('\(label)','after_\(label)')")=="0","rejected or following DDL was applied")
                    try cases.pass(label)
                }
                // A valid source DDL outside the grammar stops before mutation.
                let unsupported=try start(DDLCoverageCases.unsupported,configuration("ddl-unsupported",at:try h.boundary("source"),count:1));try waitForReader(unsupported)
                _ = try h.sql("source","ALTER TABLE poc.items ADD unsupported DECIMAL(10,2) NULL")
                _ = try finish(unsupported,"ddl-unsupported",success:false,reason:"unsupported DDL column type")
                try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='items' AND COLUMN_NAME='unsupported'") == "0","unsupported DDL mutated target")
                try require(state("ddl-unsupported","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","unsupported DDL advanced checkpoint")
                try cases.pass("ddl-unsupported")
                // A target SQL error leaves a pending DDL intent, never applied.
                _ = try h.sql("target57","REVOKE CREATE ON poc.* FROM 'apply_fixture'@'%'")
                let denied=try start(DDLCoverageCases.denied,configuration("ddl-denied",at:try h.boundary("source"),count:1));try waitForReader(denied)
                _ = try h.sql("source","CREATE TABLE poc.denied(id INT PRIMARY KEY)")
                _ = try finish(denied,"ddl-denied",success:false,reason:"target SQL error")
                try require(state("ddl-denied","SELECT status FROM ddl_intents") == "PENDING","failed DDL intent lost")
                try require(state("ddl-denied","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","failed DDL advanced checkpoint")
                try cases.pass("ddl-denied")
                report["ddl_policy"]="unchanged DDL; source InnoDB and both replicas MyISAM via local defaults"
                report["ddl_steps"]=changes.map{$0.sql};report["ddl_result"]=ddlResult
            } else if mode == "gtid" {
                // Additional accepted shapes: multi-row statement and key change.
                let edgeStart = try h.boundary("source"), edgeNativeStart = try h.boundary("native"), edgeTargetStart = try h.boundary("target57")
                let edge = try start(QualificationCase("multirow", "Replicate multirow INSERT and DELETE with a primary-key update"),configuration("multirow",at:edgeStart,count:3)); try waitForReader(edge)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(10,'ten',10),(11,'eleven',18446744073709551615); UPDATE poc.items SET id=12,value='twelve' WHERE id=11; DELETE FROM poc.items WHERE id IN (10,12)")
                let edgeResult = try finish(edge,"multirow",success:true)
                try require(edgeResult["rowsApplied"] as? Int == 5 && h.rows("target57") == Fixture.final,"multirow/key-change application differs")
                let edgeEnd = try h.boundary("source")
                _ = try h.sql("native","START REPLICA")
                let wait = try h.sql("native","SELECT SOURCE_POS_WAIT('\(edgeEnd.file)',\(edgeEnd.position),30)")
                try require(wait != "NULL" && wait != "-1" && h.rows("native") == Fixture.final,"native multirow/key-change differs")
                _ = try h.sql("native","STOP REPLICA")
                let expectedEdges = [RowOperation("insert",after:["10","ten","10"]),RowOperation("insert",after:["11","eleven","18446744073709551615"]),RowOperation("update",before:["11","eleven","18446744073709551615"],after:["12","twelve","18446744073709551615"]),RowOperation("delete",before:["10","ten","10"]),RowOperation("delete",before:["12","twelve","18446744073709551615"])]
                for (service,from,to) in [("source",edgeStart,edgeEnd),("native",edgeNativeStart,try h.boundary("native")),("target57",edgeTargetStart,try h.boundary("target57"))] {
                    try Comparison.operations(h.capture(service,start:from,end:to),expected:expectedEdges)
                    let dir = output.appendingPathComponent(service)
                    try FileManager.default.copyItem(at:dir.appendingPathComponent("operations.json"),to:dir.appendingPathComponent("multirow-operations.json"))
                }
                try cases.pass("multirow")
                // Exact wire/bind values get an independent HEX-based SQL oracle;
                // the mysqlbinlog text normalizer deliberately covers only items.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.exact_values(id BIGINT PRIMARY KEY,u INT UNSIGNED NOT NULL,b BIGINT UNSIGNED NOT NULL,t VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL,v VARBINARY(100) NULL) ENGINE=\(engine)")
                }
                let exactConfig = configuration("exact-values",at:try h.boundary("source"),count:3)
                let exact = try start(QualificationCase("exact-values", "Preserve integer extremes, UTF-8 and binary bytes, NULL and empty values"),exactConfig); try waitForReader(exact)
                _ = try h.sql("native","START REPLICA")
                func verifyExact(_ count: Int,_ expected: String) throws {
                    let end = Date().addingTimeInterval(15)
                    // Use process progress for a live barrier. A host SQLite
                    // reader cannot safely share WAL locking/mmap with Docker's VM.
                    func appliedCount() throws -> Int {
                        let logs = try docker(["logs",exact]).stdout
                        guard let last = String(decoding:logs,as:UTF8.self).split(separator:"\n").last,
                              let value = try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any] else { return 0 }
                        return value["transactionsApplied"] as? Int ?? 0
                    }
                    while try appliedCount() != count && Date() < end { Thread.sleep(forTimeInterval:0.1) }
                    try require(appliedCount() == count,"exact value apply did not reach barrier")
                    let boundary = try h.boundary("source")
                    let reached = try h.sql("native","SELECT SOURCE_POS_WAIT('\(boundary.file)',\(boundary.position),15)")
                    try require(reached != "NULL" && reached != "-1","exact value native barrier failed")
                    for service in h.services {
                        let actual = try h.sql(service,"SELECT id,u,b,IFNULL(HEX(t),'NULL'),IFNULL(HEX(v),'NULL') FROM poc.exact_values ORDER BY id")
                        try require(actual == expected,"\(service) exact values differ at group \(count)")
                        try actual.write(to:output.appendingPathComponent("\(service)-exact-\(count).tsv"),atomically:true,encoding:.utf8)
                    }
                }
                _ = try h.sql("source","INSERT INTO poc.exact_values VALUES(-9223372036854775808,4294967295,18446744073709551615,CONVERT(0x00275C09F09F9088C3A965CC812020 USING utf8mb4),0x00FF275C),(9223372036854775807,0,0,NULL,NULL)")
                try verifyExact(1,"-9223372036854775808\t4294967295\t18446744073709551615\t00275C09F09F9088C3A965CC812020\t00FF275C\n9223372036854775807\t0\t0\tNULL\tNULL")
                _ = try h.sql("source","UPDATE poc.exact_values SET id=0,t=NULL,v=X'' WHERE id=-9223372036854775808")
                try verifyExact(2,"0\t4294967295\t18446744073709551615\tNULL\t\n9223372036854775807\t0\t0\tNULL\tNULL")
                _ = try h.sql("source","DELETE FROM poc.exact_values WHERE id=9223372036854775807")
                try verifyExact(3,"0\t4294967295\t18446744073709551615\tNULL") // ProcessRunner trims the final tab.
                _ = try finish(exact,"exact-values",success:true)
                _ = try h.sql("native","STOP REPLICA")
                try cases.pass("exact-values")
                report["exact_values"] = "integer_extremes_utf8_binary_null_empty_passed"
                // One process discovers two new names and a non-leading key.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.ordered_a(payload VARCHAR(30) NULL,k BIGINT UNSIGNED PRIMARY KEY) ENGINE=\(engine); CREATE TABLE poc.ordered_b(flag INT NOT NULL,blob_value VARBINARY(10) NULL,k INT PRIMARY KEY) ENGINE=\(engine)")
                }
                let discovery=try start(QualificationCase("discovery", "Discover multiple tables with non-leading primary keys and persist their schemas"),configuration("discovery",at:try h.boundary("source"),count:4)); try waitForReader(discovery)
                _ = try h.sql("native","START REPLICA")
                _ = try h.sql("source","INSERT INTO poc.ordered_a VALUES('first',18446744073709551615); INSERT INTO poc.ordered_b VALUES(-1,0x00FF,17); UPDATE poc.ordered_a SET payload='changed' WHERE k=18446744073709551615; DELETE FROM poc.ordered_b WHERE k=17")
                _ = try finish(discovery,"discovery",success:true)
                let discoveryEnd=try h.boundary("source")
                let discoveryWait=try h.sql("native","SELECT SOURCE_POS_WAIT('\(discoveryEnd.file)',\(discoveryEnd.position),15)")
                try require(discoveryWait != "NULL" && discoveryWait != "-1","discovery native barrier failed")
                for service in h.services {
                    try require(h.sql(service,"SELECT payload,k FROM poc.ordered_a") == "changed\t18446744073709551615","discovered ordered columns differ")
                    try require(h.sql(service,"SELECT COUNT(*) FROM poc.ordered_b") == "0","discovered second table differs")
                }
                try require(state("discovery","SELECT COUNT(*) FROM schemas") == "2","schema discovery was not persisted")
                _ = try h.sql("native","STOP REPLICA")
                try cases.pass("discovery")
                report["automatic_discovery"]="multiple_tables_nonleading_keys_MINIMAL_and_FULL"
                for test in [
                    QualificationCase("absent-schema", "Reject a missing target table without advancing the checkpoint"),
                    QualificationCase("incompatible-schema", "Reject target primary-key signedness incompatible with source metadata")
                ] {
                    let label = test.id
                    let table=label == "absent-schema" ? "absent_schema" : "incompatible_schema"
                    _ = try h.sql("source","SET SESSION sql_log_bin=0; CREATE TABLE poc.\(table)(k INT UNSIGNED PRIMARY KEY) ENGINE=InnoDB")
                    if label == "incompatible-schema" {
                        _ = try h.sql("target57","CREATE TABLE poc.\(table)(k INT PRIMARY KEY) ENGINE=MyISAM")
                    }
                    let rejected=try start(test,configuration(label,at:try h.boundary("source"),count:1)); try waitForReader(rejected)
                    _ = try h.sql("source","INSERT INTO poc.\(table) VALUES(1)")
                    _ = try finish(rejected,label,success:false,reason:label == "absent-schema" ? "single primary-key" : "signedness")
                    try require(state(label,"SELECT transactions_applied FROM state") == "0","invalid schema advanced checkpoint")
                    try cases.pass(label)
                }
                // Existing state is never silently reset or used for an unsafe replay.
                _ = try finish(start(QualificationCase("existing", "Reject initialization over an existing replication state directory"),positiveConfig),"existing",success:false,reason:"state directory must be new")
                try cases.pass("existing")
                let afterSchemaFailures=try h.boundary("source")
                _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(afterSchemaFailures.file)',SOURCE_LOG_POS=\(afterSchemaFailures.position)")
                // Before-image mismatch must publish no applied transaction.
                _ = try h.sql("target57","UPDATE poc.items SET value='drift' WHERE id=1")
                let beforeMismatch = try h.rows("target57")
                let mismatch = try start(QualificationCase("mismatch", "Reject a before-image mismatch without changing rows or advancing progress"),configuration("mismatch",at:try h.boundary("source"),count:1)); try waitForReader(mismatch)
                _ = try h.sql("source","UPDATE poc.items SET value='next' WHERE id=1")
                _ = try finish(mismatch,"mismatch",success:false,reason:"before-image mismatch")
                try require(h.rows("target57") == beforeMismatch && state("mismatch","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "BLOCKED|0|0","mismatch mutated or advanced target")
                try cases.pass("mismatch")
                _ = try h.sql("target57","UPDATE poc.items SET value='next' WHERE id=1")
                // Native's known multi-statement MyISAM rejection: Swift is
                // allowed to reject the shape before its first target write.
                let rejectedRows = try h.rows("target57")
                let multiple = try start(QualificationCase("multistatement", "Reject a multi-statement transaction; confirm native MyISAM error 1837"),configuration("multistatement",at:try h.boundary("source"),count:1)); try waitForReader(multiple)
                _ = try h.sql("native","START REPLICA")
                _ = try h.sql("source","BEGIN; INSERT INTO poc.items VALUES(99,'reject',99); UPDATE poc.items SET value='not-applied' WHERE id=1; COMMIT")
                _ = try finish(multiple,"multistatement",success:false,reason:"single-statement")
                let failedEnd = try h.boundary("source")
                _ = try h.sql("native","SELECT SOURCE_POS_WAIT('\(failedEnd.file)',\(failedEnd.position),10)")
                try require(h.status()["Last_SQL_Errno"] == "1837","native rejection differs")
                try require(h.rows("target57") == rejectedRows && state("multistatement","SELECT transactions_applied FROM state") == "0","unsupported group partially applied")
                _ = try h.sql("native","STOP REPLICA")
                try cases.pass("multistatement")
                // Native channel exclusion is checked even before source capture.
                _ = try h.sql("target57","CHANGE MASTER TO MASTER_HOST='source',MASTER_USER='invalid-fixture',MASTER_PASSWORD='invalid',MASTER_CONNECT_RETRY=1,MASTER_SSL=1; START SLAVE IO_THREAD")
                _ = try finish(start(QualificationCase("native-channel", "Refuse to start while a native replication channel is running"),configuration("native-channel",at:try h.boundary("source"),count:1)),"native-channel",success:false,reason:"native replication channel")
                try cases.pass("native-channel")
                _ = try h.sql("target57","STOP SLAVE; RESET SLAVE ALL")
                _ = try h.sql("target57","CREATE TRIGGER poc.reject_trigger BEFORE INSERT ON poc.items FOR EACH ROW SET NEW.value='trigger'")
                let trigger = try start(QualificationCase("trigger", "Reject a target table with a trigger before applying rows"),configuration("trigger",at:try h.boundary("source"),count:1)); try waitForReader(trigger)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(88,'trigger-rejected',88)")
                _ = try finish(trigger,"trigger",success:false,reason:"triggers are unsupported")
                _ = try h.sql("target57","DROP TRIGGER poc.reject_trigger")
                try require(h.rows("target57") == rejectedRows,"preflight rejection changed rows")
                try cases.pass("trigger")
                // A later row error cannot roll back an earlier MyISAM write.
                _ = try h.sql("target57","INSERT INTO poc.items VALUES(21,'collision',21)")
                let partial = try start(QualificationCase("partial", "Record partial MyISAM writes and pending intent after a duplicate-key failure"),configuration("partial",at:try h.boundary("source"),count:1)); try waitForReader(partial)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(20,'first',20),(21,'second',21)")
                _ = try finish(partial,"partial",success:false,reason:"primary key already exists")
                try require(h.sql("target57","SELECT id,value FROM poc.items WHERE id IN (20,21) ORDER BY id") == "20\tfirst\n21\tcollision","partial MyISAM effects differ")
                try require(state("partial","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||COALESCE(applied_position,'NULL') FROM state") == "BLOCKED|0|0|NULL","partial group advanced checkpoint")
                try require(state("partial","SELECT ordinal||'|'||status FROM row_intents ORDER BY ordinal") == "0|DONE\n1|PENDING","partial row intents differ")
                try cases.pass("partial")
                // Missing DELETE row is an error, not an idempotent success.
                _ = try h.sql("target57","DELETE FROM poc.items WHERE id=3")
                let missing = try start(QualificationCase("missing", "Stop on a missing DELETE row without advancing the checkpoint"),configuration("missing",at:try h.boundary("source"),count:1)); try waitForReader(missing)
                _ = try h.sql("source","DELETE FROM poc.items WHERE id=3")
                _ = try finish(missing,"missing",success:false,reason:"missing row")
                try require(state("missing","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","missing delete advanced checkpoint")
                try cases.pass("missing")
                report["negative_checks"] = ["existing_state","before_image_mismatch","multistatement_native_1837","native_channel","trigger","partial_multirow","missing_delete"]
                report["extended_dml"] = "multirow_insert_delete_and_primary_key_update_passed"
            }
        } catch { failure = cases.fail(error); report["error"] = String(describing:failure!) }
        report["cases"] = cases.results
        stage("cleaning up")
        var cleanup: [String] = []
        for client in clients {
            if let logs = try? docker(["logs",client]) { try? (logs.stdout + logs.stderr).write(to:output.appendingPathComponent(client + ".log")) }
            do { _ = try docker(["rm","-f",client]) } catch { cleanup.append(String(describing:error)) }
        }
        if helperCreated {
            do { _ = try docker(["cp",evidenceHelper + ":/evidence/.",output.path]) } catch { cleanup.append("evidence copy: " + String(describing:error)) }
            do { _ = try docker(["rm","-f",evidenceHelper]) } catch { cleanup.append(String(describing:error)) }
        }
        if started {
            if let logs = try? h.compose(["logs","--no-color"]) { try? (logs.stdout + logs.stderr).write(to:output.appendingPathComponent("containers.log")) }
            do { _ = try h.compose(["down","--volumes","--remove-orphans"]) } catch { cleanup.append(String(describing:error)) }
        }
        if volumeCreated {
            do { _ = try docker(["volume","rm",evidenceVolume]) } catch { cleanup.append(String(describing:error)) }
        }
        report["cleanup"] = cleanup.isEmpty ? "passed" : cleanup.joined(separator:"\n")
        if !cleanup.isEmpty && failure == nil { failure = LabError("DML cleanup failed") }
        report["result"] = failure == nil ? "passed" : "failed"
        try writeJSON(report,to:output.appendingPathComponent("result.json"))
        if let coverageInputs, let coverageContracts, !coverageRuntime.isEmpty {
            try DDLCoverageEvidence.save(root: root, output: output, profile: coverageProfile, inputs: coverageInputs,
                contracts: coverageContracts, runtime: coverageRuntime, results: cases.results)
        }
        if let failure { throw LabError("\(failure); evidence: \(output.path)") }
        stage(ddl ? "PASS: ordered DDL/DML, schemas, data, binlogs and checkpoints" : "PASS: DML data, binlogs and applied checkpoints")
    }
}
