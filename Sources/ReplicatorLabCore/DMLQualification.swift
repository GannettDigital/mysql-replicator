import Foundation

public enum DMLQualification {
    public static func run(root: URL, build: Bool = true, ddl: Bool = false, selection: SuiteSelection = .init()) throws {
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
        for mode in selection.modes { try runCase(root:root,image:qualifiedImage,mode:mode,ddl:ddl,coverageInputs:coverageInputs,coverageContracts:coverageContracts,selection:selection) }
    }
    private static func runCase(root: URL,image: String,mode: String,ddl: Bool,coverageInputs: [String: String]?,coverageContracts: [String: String]?,selection: SuiteSelection) throws {
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
        report["selection"] = selection.fields
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
        func start(_ test: QualificationCase,_ config: [String:Any], initialize: Bool = true) throws -> String {
            try cases.begin(test)
            let label = test.id
            try writeYAML(config,to:output.appendingPathComponent(label + ".yaml"))
            _ = try docker(["cp",output.appendingPathComponent(label + ".yaml").path,evidenceHelper + ":/evidence/" + label + ".yaml"])
            let name = h.project + "-" + label; clients.append(name)
            _ = try docker(["run","-d","--name",name,"--platform","linux/amd64","--network",h.project + "_fixture",
                "--mount","type=volume,src=\(evidenceVolume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only",
                "--entrypoint","/usr/local/bin/mysql-replicator",image,"run","--config","/evidence/\(label).yaml"] + (initialize ? ["--initialize"] : []))
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
        func waitProgress(_ name: String, _ predicate: ([String:Any]) -> Bool) throws {
            let deadline=Date().addingTimeInterval(45)
            while Date() < deadline {
                let logs=try docker(["logs",name])
                let records=logs.stdout.split(separator:10).compactMap { try? JSONSerialization.jsonObject(with:Data($0)) as? [String:Any] }
                if records.contains(where:predicate) { return }
                try require(docker(["inspect",name,"--format","{{.State.Running}}"]).text == "true","reconnect client stopped: "+String(decoding:logs.stderr,as:UTF8.self))
                Thread.sleep(forTimeInterval:0.1)
            }
            throw LabError("reconnect progress timeout")
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
            _ = try h.sql("target57","CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX ON poc.* TO 'apply_fixture'@'%'; GRANT REPLICATION CLIENT,SUPER ON *.* TO 'apply_fixture'@'%'; GRANT SELECT ON performance_schema.* TO 'apply_fixture'@'%'")
            if ddl {_ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX ON otherdb.* TO 'apply_fixture'@'%'")}
            if ddl {
                _ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,EXECUTE ON ddlcompat.* TO 'apply_fixture'@'%'")
                _ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX ON demo.* TO 'apply_fixture'@'%'")
                for database in Set(DatabaseCreationCases.cases.map(\.database)) {
                    _ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX ON \(database).* TO 'apply_fixture'@'%'")
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
            var positiveConfig = configuration("positive",at:sourceStart,count:4)
            // Exercise direct YAML credentials; subsequent fixtures use environment variables.
            for (endpoint,password) in [("source","fixture-capture-only"),("target","fixture-apply-only")] {
                var connection=positiveConfig[endpoint] as! [String:Any]
                connection.removeValue(forKey:"passwordEnvironment"); connection["password"]=password
                positiveConfig[endpoint]=connection
            }
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
            let positiveReads = (positive["stageTimings"] as? [String:[String:Any]])?["target.read"]?["count"] as? Int
            try require(positiveReads == 3,"expected before-image reads only for UPDATE/DELETE")
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
            if !ddl && selection.includes("matrix") {
                let session = "USE poc; SET SESSION time_zone='+00:00'; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION'; "
                let originalMetadata = try h.sql("source","SELECT @@GLOBAL.binlog_row_metadata")
                for test in DMLCompatibilityCases.cases where selection.selects("matrix-"+test.id) {
                    _ = try h.sql("source","SET GLOBAL binlog_row_metadata="+(test.rowMetadata ?? originalMetadata))
                    let table="poc.matrix_"+test.id
                    for service in h.services {
                        let engine=service == "source" ? "InnoDB" : "MyISAM"
                        _ = try h.sql(service,session+"SET SESSION sql_log_bin=0; CREATE TABLE \(table)(\(test.definition)) ENGINE=\(engine) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin; "+test.setup)
                    }
                    let columns=try h.sql("source","SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_\(test.id)' ORDER BY ORDINAL_POSITION").split(separator:"\n")
                    let expressions=columns.map { "IFNULL(HEX(CAST(`"+$0.replacingOccurrences(of:"`",with:"``")+"` AS BINARY)),'<NULL>')" }.joined(separator:",")
                    let observation="SELECT \(expressions) FROM \(table) ORDER BY \(test.orderBy)"
                    for (ordinal,phase) in test.phases.enumerated() {
                        let label="matrix-\(test.id)-\(ordinal+1)"
                        let before=try h.boundary("source")
                        _ = try h.sql("source",session+phase.sql)
                        let end=try h.boundary("source")
                        let delta=try h.sql("source","SELECT GTID_SUBTRACT('\(end.gtids)','\(before.gtids)')")
                        let count=try DMLCompatibilityCases.transactionCount(delta)
                        let fixture=QualificationCase(label,"MySQL 5.7 DML compatibility: "+test.id+" phase "+String(ordinal+1))
                        if count > 0 {
                            let client=try start(fixture,configuration(label,at:before,count:count))
                            _ = try finish(client,label,success:true)
                            try require(state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||applied_position FROM state") == "STOPPED|\(count)|\(end.position)","matrix checkpoint differs")
                        } else { try cases.begin(fixture) }
                        _ = try h.sql("native","START REPLICA")
                        try ModifyIndexCases.waitNative(h,end)
                        _ = try h.sql("native","STOP REPLICA")
                        var observations:[String:String]=[:]
                        for service in h.services {
                            try require(h.sql(service,session+phase.check) == "1","\(label) independent expectation failed on \(service)")
                            observations[service]=try h.sql(service,session+observation,preserveWhitespace:true)
                        }
                        try require(observations["source"] == observations["native"] && observations["source"] == observations["target57"],"\(label) exact row bytes differ")
                        try writeJSON(["sql":phase.sql,"check":phase.check,"observations":observations,"source_before":before.json,"source_after":end.json,"gtid_count":count],to:output.appendingPathComponent(label+"-comparison.json"))
                        try cases.pass(label)
                    }
                }
                for test in DMLCompatibilityCases.rejections where selection.selects("matrix-reject-"+test.id) {
                    let label="matrix-reject-"+test.id
                    let table="poc.matrix_reject_"+test.id.replacingOccurrences(of:"-",with:"_")
                    for service in ["source","target57"] {
                        let definition=service == "source" ? test.sourceDefinition : test.targetDefinition
                        let engine=service == "source" ? "InnoDB" : "MyISAM"
                        _ = try h.sql(service,session+"SET SESSION sql_log_bin=0; CREATE TABLE \(table)(\(definition)) ENGINE=\(engine)")
                    }
                    _ = try h.sql("source","SET GLOBAL binlog_row_metadata="+test.rowMetadata)
                    let before=try h.boundary("source")
                    _ = try h.sql("source",session+test.sourceSession+"INSERT INTO \(table) VALUES"+test.values)
                    _ = try h.sql("source","SET GLOBAL binlog_row_metadata="+originalMetadata)
                    let client=try start(QualificationCase(label,"Reject incompatible or unqualified MySQL 5.7 target schema: "+test.id),configuration(label,at:before,count:1))
                    _ = try finish(client,label,success:false,reason:test.reason)
                    try require(h.sql("target57","SELECT COUNT(*) FROM \(table)") == "0" && state(label,"SELECT transactions_applied FROM state") == "0","rejected matrix case changed target or checkpoint")
                    try cases.pass(label)
                }
                // Negative fixtures are intentionally absent on the native reference.
                let after=try h.boundary("source")
                _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(after.file)',SOURCE_LOG_POS=\(after.position)")
                report["dml_matrix"]="passed"
            }
            if !ddl && selection.includes("target-reconnect") {
                func targetConfig(_ label: String, count: Int) throws -> [String:Any] {
                    var config=configuration(label,at:try h.boundary("source"),count:count)
                    config["targetReconnect"]=["initialDelaySeconds":1,"maximumDelaySeconds":1,"maximumAttempts":60]
                    return config
                }
                func killWriter() throws {
                    let id=try h.sql("target57","SELECT ID FROM information_schema.PROCESSLIST WHERE USER='apply_fixture'")
                    try require(Int(id) != nil,"missing unique target writer")
                    _ = try h.sql("target57","KILL CONNECTION "+id)
                }
                func waitPartial(_ table: String) throws {
                    let deadline=Date().addingTimeInterval(30)
                    while true {
                        let writes=Int(try h.sql("target57","SELECT COUNT_WRITE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='poc' AND OBJECT_NAME='\(table)'")) ?? 0
                        if (1..<8000).contains(writes) { return }
                        try require(writes < 8000 && Date() < deadline,"missed active target group")
                        Thread.sleep(forTimeInterval:0.02)
                    }
                }
                for service in h.services {
                    let engine=service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.target_reconnect(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine); CREATE TABLE poc.target_drain(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine); CREATE TABLE poc.target_uncertain(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine)")
                }
                let safe=try start(QualificationCase("target-reconnect","Reconnect after idle socket loss and target restart without replaying acknowledged writes"),targetConfig("target-reconnect",count:3))
                try waitForReader(safe)
                _ = try h.sql("source","INSERT INTO poc.target_reconnect VALUES(1,10)")
                try waitProgress(safe) { $0["transactionsApplied"] as? Int == 1 }
                try killWriter()
                try waitProgress(safe) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                try waitForReader(safe)
                _ = try h.sql("source","UPDATE poc.target_reconnect SET v=11 WHERE id=1")
                try waitProgress(safe) { $0["transactionsApplied"] as? Int == 2 }
                _ = try h.compose(["stop","-t","30","target57"])
                try waitProgress(safe) { ($0["targetReconnectAttempts"] as? Int ?? 0) >= 2 }
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","target57"],timeout:150)
                try waitForReader(safe)
                _ = try h.sql("source","INSERT INTO poc.target_reconnect VALUES(2,20)")
                let safeResult=try finish(safe,"target-reconnect",success:true)
                try require((safeResult["targetReconnectAttempts"] as? Int ?? 0) >= 2,"target reconnect not exercised")
                try require(h.sql("target57","SELECT id,v FROM poc.target_reconnect ORDER BY id") == "1\t11\n2\t20","target reconnect rows differ")
                try require(state("target-reconnect","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|3|3","target reconnect checkpoint differs")
                try cases.pass("target-reconnect")

                // Planned maintenance drains the already-journaled group, then
                // a separate invocation resumes after mysqld has restarted.
                var drainConfig=try targetConfig("target-drain",count:2)
                drainConfig["batch"]=["maximumInsertRows":4]
                let draining=try start(QualificationCase("target-drain","SIGUSR1 finishes active writes and saves a resumable STOPPED checkpoint"),drainConfig)
                try waitForReader(draining)
                _ = try h.sql("source","INSERT INTO poc.target_drain VALUES "+(1...8000).map { "(\($0),\($0))" }.joined(separator:","))
                try waitPartial("target_drain")
                _ = try docker(["kill","--signal","USR1",draining])
                let drained=try finish(draining,"target-drain",success:true)
                try require(drained["drainRequested"] as? Bool == true,"drain was not reported")
                try require(state("target-drain","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|1|8000","drain did not finish the active group")
                try require(state("target-drain","SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "0","drain left pending writes")
                try cases.pass("target-drain")
                _ = try h.compose(["stop","-t","30","target57"])
                // Resume while target is still down: initial connection attempts
                // must retry without changing the saved applied checkpoint.
                var resumedConfig=drainConfig
                var resumedSource=resumedConfig["source"] as! [String:Any]; resumedSource["stopAfterTransactions"]=1; resumedConfig["source"]=resumedSource
                let resumed=try start(QualificationCase("target-drain-resume","Wait for target startup and resume a drained checkpoint"),resumedConfig,initialize:false)
                try waitProgress(resumed) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","target57"],timeout:150)
                try waitForReader(resumed)
                _ = try h.sql("source","UPDATE poc.target_drain SET v=v+1 WHERE id=1")
                _ = try finish(resumed,"target-drain-resume",success:true)
                try require(h.sql("target57","SELECT COUNT(*),SUM(v) FROM poc.target_drain") == "8000\t32004001","drained resume duplicated or lost rows")
                try cases.pass("target-drain-resume")

                let waiting=try start(QualificationCase("target-backoff-drain","Drain exits cleanly while the target is unavailable"),targetConfig("target-backoff-drain",count:1))
                try waitProgress(waiting) { $0["lifecycle"] as? String == "RUNNING" }
                try waitForReader(waiting)
                _ = try h.compose(["stop","-t","30","target57"])
                try waitProgress(waiting) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                _ = try docker(["kill","--signal","USR1",waiting])
                _ = try finish(waiting,"target-backoff-drain",success:true)
                try require(state("target-backoff-drain","SELECT lifecycle||'|'||transactions_applied FROM state") == "STOPPED|0","target backoff drain was not clean")
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","target57"],timeout:150)
                try cases.pass("target-backoff-drain")

                // Discover first, then hold a table lock until the applier has
                // submitted INSERT. Kill that socket while its result is unknown.
                var uncertainConfig=try targetConfig("target-uncertain",count:2)
                uncertainConfig["batch"]=["maximumInsertRows":4]
                let uncertain=try start(QualificationCase("target-uncertain","Lost mutation reply blocks and preserves statement/row evidence without replay"),uncertainConfig)
                try waitForReader(uncertain)
                _ = try h.sql("source","INSERT INTO poc.target_uncertain VALUES(0,0)")
                try waitProgress(uncertain) { $0["transactionsApplied"] as? Int == 1 }
                _ = try h.compose(["exec","-d","-e","MYSQL_PWD=fixture-root-only","target57","mysql","--no-defaults","-uroot","-e","LOCK TABLES poc.target_uncertain WRITE; DO SLEEP(30); UNLOCK TABLES"])
                let lockDeadline=Date().addingTimeInterval(15)
                while try h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(30)'") != "1" {
                    try require(Date() < lockDeadline,"target blocker failed to start"); Thread.sleep(forTimeInterval:0.05)
                }
                _ = try h.sql("source","INSERT INTO poc.target_uncertain VALUES(1,1),(2,2),(3,3),(4,4)")
                let queryDeadline=Date().addingTimeInterval(15)
                while try h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='apply_fixture' AND INFO LIKE 'INSERT INTO%'") != "1" {
                    try require(Date() < queryDeadline,"target mutation was not submitted"); Thread.sleep(forTimeInterval:0.05)
                }
                try killWriter()
                _ = try finish(uncertain,"target-uncertain",success:false,reason:"target connection")
                let blocker=try h.sql("target57","SELECT ID FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(30)'")
                if Int(blocker) != nil { _ = try h.sql("target57","KILL CONNECTION "+blocker) }
                try require(state("target-uncertain","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|1","uncertain target advanced checkpoint")
                let diagnostic=try state("target-uncertain","SELECT diagnostic_json FROM target_failure")
                try require(diagnostic.contains("possiblyExecuted") && diagnostic.contains("target_uncertain"),"missing target statement evidence")
                try require(h.sql("target57","SELECT COUNT(*) FROM poc.target_uncertain") == "1","uncertain write was retried")
                try cases.pass("target-uncertain")
                _ = try finish(start(QualificationCase("target-uncertain-resume","Ordinary resume refuses uncertain target writes"),uncertainConfig,initialize:false),"target-uncertain-resume",success:false,reason:"cleanly STOPPED")
                try cases.pass("target-uncertain-resume")
                let changed=try start(QualificationCase("target-reconnect-settings","Reject incompatible target settings on reconnect"),targetConfig("target-reconnect-settings",count:1))
                try waitProgress(changed) { $0["lifecycle"] as? String == "RUNNING" }
                _ = try h.sql("target57","SET GLOBAL binlog_row_image=MINIMAL")
                try killWriter()
                _ = try finish(changed,"target-reconnect-settings",success:false,reason:"target binary logging differs")
                _ = try h.sql("target57","SET GLOBAL binlog_row_image=FULL")
                try require(state("target-reconnect-settings","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","changed target settings advanced progress")
                try cases.pass("target-reconnect-settings")
                report["target_reconnect"]="safe_disconnect_restart_drain_resume_backoff_and_uncertain_reply_passed"
            }
            if !ddl && selection.includes("reconnect") {
                func killReader() throws {
                    let id=try h.sql("source","SELECT ID FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'")
                    try require(Int(id) != nil,"missing unique source reader")
                    _ = try h.sql("source","KILL CONNECTION "+id)
                }
                func reconnectConfig(_ label:String, count:Int) throws -> [String:Any] {
                    var config=configuration(label,at:try h.boundary("source"),count:count)
                    config["sourceReconnect"]=["initialDelaySeconds":1,"maximumDelaySeconds":1,"maximumAttempts":60]
                    return config
                }
                for service in h.services {
                    let engine=service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.reconnect_rows(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine); CREATE TABLE poc.reconnect_batch(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine)")
                }
                let reconnect=try start(QualificationCase("source-reconnect","Continue one applier across disconnect, rotation, source shutdown and crash/restart"),reconnectConfig("source-reconnect",count:5))
                try waitForReader(reconnect)
                _ = try h.sql("source","INSERT INTO poc.reconnect_rows VALUES(1,10)")
                try waitProgress(reconnect) { $0["transactionsApplied"] as? Int == 1 }
                try killReader()
                try waitProgress(reconnect) { $0["lifecycle"] as? String == "RECONNECTING" }
                try waitForReader(reconnect)
                _ = try h.sql("source","UPDATE poc.reconnect_rows SET v=v+1 WHERE id=1; FLUSH BINARY LOGS; INSERT INTO poc.reconnect_rows VALUES(2,20)")
                try waitProgress(reconnect) { $0["transactionsApplied"] as? Int == 3 }
                _ = try h.compose(["stop","-t","30","source"])
                try waitProgress(reconnect) { ($0["sourceReconnectAttempts"] as? Int ?? 0) >= 2 }
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","source"],timeout:150)
                try waitForReader(reconnect)
                _ = try h.sql("source","UPDATE poc.reconnect_rows SET v=v+100 WHERE id=1")
                try waitProgress(reconnect) { $0["transactionsApplied"] as? Int == 4 }
                let sourceContainer=try h.compose(["ps","-q","source"]).text
                _ = try docker(["kill","--signal","KILL",sourceContainer])
                try waitProgress(reconnect) { ($0["sourceReconnectAttempts"] as? Int ?? 0) >= 3 }
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","source"],timeout:150)
                try waitForReader(reconnect)
                _ = try h.sql("source","INSERT INTO poc.reconnect_rows VALUES(3,30)")
                let reconnected=try finish(reconnect,"source-reconnect",success:true)
                try require((reconnected["sourceReconnectAttempts"] as? Int ?? 0) >= 3,"source interruptions did not reconnect")
                _ = try h.sql("native","START REPLICA")
                try ModifyIndexCases.waitNative(h,try h.boundary("source"))
                _ = try h.sql("native","STOP REPLICA")
                for service in h.services {
                    try require(h.sql(service,"SELECT id,v FROM poc.reconnect_rows ORDER BY id") == "1\t111\n2\t20\n3\t30","source reconnect duplicated or lost writes")
                }
                try require(state("source-reconnect","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|5|5","source reconnect reset the transaction limit or checkpoint")
                try require(state("source-reconnect","SELECT COUNT(*) FROM groups WHERE status='APPLIED'") == "5","reconnect duplicated journal groups")
                try cases.pass("source-reconnect")

                var batchConfig=try reconnectConfig("source-reconnect-batch",count:2)
                batchConfig["batch"]=["maximumInsertRows":4]
                let batchClient=try start(QualificationCase("source-reconnect-batch","Finish an active target group after source loss, then reconnect without replaying it"),batchConfig)
                try waitForReader(batchClient)
                _ = try h.sql("source","INSERT INTO poc.reconnect_batch VALUES "+(1...8000).map { "(\($0),\($0))" }.joined(separator:","))
                let writeDeadline=Date().addingTimeInterval(30)
                while true {
                    let writes=Int(try h.sql("target57","SELECT COUNT_WRITE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='poc' AND OBJECT_NAME='reconnect_batch'")) ?? 0
                    if (1..<8000).contains(writes) { break }
                    try require(writes < 8000 && Date() < writeDeadline,"missed active target batch")
                    Thread.sleep(forTimeInterval:0.02)
                }
                try killReader()
                try waitProgress(batchClient) { $0["lifecycle"] as? String == "RECONNECTING" && $0["transactionsApplied"] as? Int == 1 }
                try waitForReader(batchClient)
                _ = try h.sql("source","UPDATE poc.reconnect_batch SET v=v+1 WHERE id=1")
                _ = try finish(batchClient,"source-reconnect-batch",success:true)
                _ = try h.sql("native","START REPLICA")
                try ModifyIndexCases.waitNative(h,try h.boundary("source"))
                _ = try h.sql("native","STOP REPLICA")
                for service in h.services { try require(h.sql(service,"SELECT COUNT(*),SUM(v) FROM poc.reconnect_batch") == "8000\t32004001","active batch reconnect differs") }
                try require(state("source-reconnect-batch","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|2|8001","active batch checkpoint differs")
                try require(state("source-reconnect-batch","SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "0","reconnect left unresolved writes")
                try cases.pass("source-reconnect-batch")

                let waiting=try start(QualificationCase("source-reconnect-cancel","Stop cleanly during reconnect backoff"),reconnectConfig("source-reconnect-cancel",count:1))
                try waitForReader(waiting)
                _ = try h.compose(["stop","-t","30","source"])
                try waitProgress(waiting) { $0["lifecycle"] as? String == "RECONNECTING" }
                _ = try docker(["kill","--signal","TERM",waiting])
                _ = try finish(waiting,"source-reconnect-cancel",success:true)
                try require(state("source-reconnect-cancel","SELECT lifecycle||'|'||transactions_applied FROM state") == "STOPPED|0","backoff cancellation was not clean")
                _ = try h.compose(["up","-d","--wait","--wait-timeout","120","source"],timeout:150)
                try cases.pass("source-reconnect-cancel")
                let changed=try start(QualificationCase("source-reconnect-settings","Reject incompatible source settings on reconnect without advancing progress"),reconnectConfig("source-reconnect-settings",count:1))
                try waitForReader(changed)
                _ = try h.sql("source","SET GLOBAL binlog_row_image=MINIMAL")
                try killReader()
                let changedResult=try finish(changed,"source-reconnect-settings",success:false,reason:"source identity/settings differ")
                _ = try h.sql("source","SET GLOBAL binlog_row_image=FULL")
                try require(changedResult["progress"].flatMap { $0 as? [String:Any] }?["sourceReconnectAttempts"] as? Int == 1,"incompatible source settings were retried")
                try require(state("source-reconnect-settings","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","changed source advanced progress")
                try cases.pass("source-reconnect-settings")
                report["source_reconnect"]="disconnect_rotation_shutdown_crash_active_batch_cancellation_and_settings_checks_passed"
            }
            if ddl {
                if selection.includes("filters") {
                    let test = DDLCoverageCases.wildcardFilter
                    let patterns = ["temp.%", "poc.ignore\\_%", "scratch_.%"]
                    let nativePatterns = patterns.map { "'" + $0.replacingOccurrences(of:"\\",with:"\\\\") + "'" }.joined(separator:",")
                    _ = try h.sql("native","CHANGE REPLICATION FILTER REPLICATE_WILD_IGNORE_TABLE=(\(nativePatterns)); START REPLICA")
                    let begin = try h.boundary("source"), nativeBegin = try h.boundary("native"), targetBegin = try h.boundary("target57")
                    let workload = [
                        "CREATE DATABASE temp",
                        "CREATE TABLE temp.opaque(id INT PRIMARY KEY,d DECIMAL(20,4),j JSON,ts DATETIME) ENGINE=InnoDB",
                        "INSERT INTO temp.opaque VALUES(1,123.45,JSON_OBJECT('a',1),NOW())",
                        "UPDATE temp.opaque SET d=456.78 WHERE id=1",
                        "BEGIN; INSERT INTO temp.opaque VALUES(2,1,NULL,NULL); UPDATE temp.opaque SET d=2 WHERE id=2; COMMIT",
                        "ALTER TABLE temp.opaque MODIFY d DECIMAL(25,6)",
                        "CREATE INDEX ignored_index ON temp.opaque(d)",
                        "RENAME TABLE temp.opaque TO temp.renamed",
                        "DELETE FROM temp.renamed WHERE id=1",
                        "CREATE TABLE poc.ignore_table(id INT PRIMARY KEY,d DECIMAL(20,4)) ENGINE=InnoDB",
                        "INSERT INTO poc.ignore_table VALUES(1,12.34)",
                        "CREATE TABLE poc.ignoreXtable(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL)",
                        "DROP TABLE poc.ignoreXtable",
                        "CREATE DATABASE scratch1",
                        "CREATE TABLE scratch1.t(id INT PRIMARY KEY) ENGINE=InnoDB",
                        "INSERT INTO scratch1.t VALUES(1)",
                        "CREATE TABLE temp.mixed(id INT PRIMARY KEY,n INT)",
                        "INSERT INTO temp.mixed VALUES(91,1)",
                        "INSERT INTO poc.items VALUES(91,'included',1)",
                        "UPDATE poc.items p JOIN temp.mixed t ON p.id=t.id SET p.quantity=2,t.n=2 WHERE p.id=91",
                        "DELETE FROM poc.items WHERE id=91",
                        "DROP TABLE temp.mixed,temp.renamed",
                        "DROP TABLE poc.ignore_table",
                        "DROP DATABASE scratch1",
                        "DROP DATABASE temp"
                    ]
                    var config = configuration(test.id,at:begin,count:workload.count); config["replicateWildIgnoreTable"] = patterns
                    let applying = try start(test,config); try waitForReader(applying)
                    for sql in workload { _ = try h.sql("source",sql) }
                    let result = try finish(applying,test.id,success:true), end = try h.boundary("source")
                    try ModifyIndexCases.waitNative(h,end); _ = try h.sql("native","STOP REPLICA")
                    try require(result["transactionsApplied"] as? Int == workload.count && result["rowsApplied"] as? Int == 3 && result["ddlApplied"] as? Int == 2 && result["appliedGTIDSet"] as? String == end.gtids,"wildcard filtering checkpoint/counters differ")
                    for service in ["native","target57"] {
                        try require(h.rows(service) == Fixture.final,"filtered workload changed retained rows")
                        try require(h.sql(service,"SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ('temp','scratch1')") == "0","excluded schema reached replica")
                        try require(h.sql(service,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ignore_table'") == "0","escaped wildcard did not exclude table")
                    }
                    let expected = [RowOperation("insert",after:["91","included","1"]),RowOperation("update",before:["91","included","1"],after:["91","included","2"]),RowOperation("delete",before:["91","included","2"])]
                    for (service,from) in [("native",nativeBegin),("target57",targetBegin)] {
                        try Comparison.operations(h.capture(service,start:from,end:h.boundary(service)),expected:expected)
                    }
                    try writeJSON(["patterns":patterns,"workload":workload,"summary":result,"native_status":try h.status()],to:output.appendingPathComponent("wild-ignore.json"))
                    try cases.pass(test.id)
                    // Resume uses persisted progress, not the stale baseline in config.
                    let resumedTest = DDLCoverageCases.wildcardResume
                    var resumeConfig = config
                    var source = resumeConfig["source"] as! [String:Any]; source["stopAfterTransactions"] = 1; resumeConfig["source"] = source
                    let resumed = try start(resumedTest,resumeConfig,initialize:false); try waitForReader(resumed)
                    _ = try h.sql("source","UPDATE poc.items SET value='after-filter-resume' WHERE id=1")
                    let resumedResult = try finish(resumed,resumedTest.id,success:true)
                    try require(resumedResult["transactionsApplied"] as? Int == workload.count+1 && resumedResult["rowsApplied"] as? Int == 4,"filtered resume replayed/reset progress")
                    let saved = try state(test.id,"SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||ddl_applied FROM state")
                    try require(saved == "STOPPED|\(workload.count+1)|4|2","filtered durable state differs")
                    try require(state(test.id,"SELECT COUNT(*) FROM row_intents") == "4" && state(test.id,"SELECT COUNT(*) FROM ddl_intents") == "2" && state(test.id,"SELECT COUNT(*) FROM schemas") == "2","excluded work created intents or schemas")
                    try cases.pass(resumedTest.id)
                    _ = try h.sql("native","START REPLICA"); try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA; CHANGE REPLICATION FILTER REPLICATE_WILD_IGNORE_TABLE=()")
                    let rejectedTest = DDLCoverageCases.wildcardRejection
                    var rejectionConfig = configuration(rejectedTest.id,at:try h.boundary("source"),count:2); rejectionConfig["replicateWildIgnoreTable"] = patterns
                    let rejected = try start(rejectedTest,rejectionConfig); try waitForReader(rejected)
                    _ = try h.sql("source","CREATE TABLE poc.filter_included(id INT PRIMARY KEY,d JSON); INSERT INTO poc.items VALUES(92,'must-not-apply',1)")
                    _ = try finish(rejected,rejectedTest.id,success:false,reason:"unsupported DDL column type")
                    try require(state(rejectedTest.id,"SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0" && state(rejectedTest.id,"SELECT COUNT(*) FROM ddl_intents") == "0","included DDL bypassed fail-stop policy")
                    try require(h.sql("target57","SELECT COUNT(*) FROM poc.items WHERE id=92") == "0","included DDL failure did not stop following row")
                    try cases.pass(rejectedTest.id)
                    _ = try h.sql("native","START REPLICA"); try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                    for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; DROP TABLE IF EXISTS poc.filter_included; DELETE FROM poc.items WHERE id=92") }
                    // Restore the shared basic fixture without adding source events.
                    for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; UPDATE poc.items SET value='" + Fixture.final[0][1] + "' WHERE id=1") }
                }

                if selection.includes("compatibility") {
                    let session = "SET NAMES utf8mb4 COLLATE utf8mb4_bin; SET SESSION time_zone='+00:00'; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION'; "
                    func resetCompatibility(_ nativeInnoDB: Bool = false) throws {
                        for service in h.services {
                            let engine = service == "source" || (service == "native" && nativeInnoDB) ? "InnoDB" : "MyISAM"
                            _ = try h.sql(service,"SET SESSION sql_log_bin=0; SET GLOBAL default_storage_engine=\(engine); DROP DATABASE IF EXISTS ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
                        }
                    }
                    func compatibilityBarrier(_ client: String,_ count: Int) throws {
                        try waitProgress(client) { ($0["transactionsApplied"] as? Int ?? 0) >= count }
                        try ModifyIndexCases.waitNative(h,h.boundary("source"))
                    }
                    if mode == "file-position" { stage("ENUM/SET type fixture runs only in the GTID/FULL-metadata profile") }
                    for test in DDLCompatibilityCases.cases where selection.selects(test.test.id) && !(mode == "file-position" && test.test.id == "ddl-compat-types") {
                        try resetCompatibility(test.nativeInnoDB)
                        let boundary=try h.boundary("source"),label=test.test.id
                        let count=test.steps.reduce(0){$0+$1.transactions}
                        let client=try start(test.test,configuration(label,at:boundary,count:count)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA")
                        var applied=0,observations:[[String:Any]]=[]
                        for step in test.steps {
                            // DELIMITER is a mysql CLI directive, never binlog SQL.
                            _ = try h.sql("source",session+"\n"+step.sql)
                            applied += step.transactions
                            try compatibilityBarrier(client,applied)
                            var checks:[[String:Any]]=[]
                            for check in step.checks {
                                var result:[String:String]=[:]
                                for service in h.services {
                                    let actual=try h.sql(service,session+check.sql)
                                    try require(actual==check.expected,"\(label) \(service): \(check.sql) returned \(actual), expected \(check.expected)")
                                    result[service]=actual
                                }
                                checks.append(["query":check.sql,"expected":check.expected,"results":result])
                            }
                            observations.append(["sql":step.sql,"checks":checks,"transactions":applied])
                        }
                        let result=try finish(client,label,success:true),end=try h.boundary("source")
                        _ = try h.sql("native","STOP REPLICA")
                        try require(result["transactionsApplied"] as? Int == count && result["appliedGTIDSet"] as? String == end.gtids,"compatibility checkpoint differs")
                        try require(state(label,"SELECT COUNT(*) FROM ddl_intents WHERE status!='DONE'")=="0","unfinished compatibility DDL intent")
                        if label == "ddl-compat-database" {
                            try require(state(label,"SELECT COUNT(*) FROM schemas WHERE current=1")=="1","DROP DATABASE retained stale current table schemas")
                        }
                        try writeJSON(["steps":observations,"summary":result],to:output.appendingPathComponent(label+"-observations.json"))
                        try cases.pass(label)
                    }
                    for (test,sql,reason) in [
                        (DDLCompatibilityCases.trigger,"CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=7","DDL policy rejects triggers"),
                        (DDLCompatibilityCases.event,"CREATE EVENT ddlcompat.e ON SCHEDULE EVERY 1 DAY DISABLE DO INSERT INTO ddlcompat.t VALUES(99,99)","DDL policy rejects events")
                    ] where selection.selects(test.id) {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        let before=try h.boundary("source"),label=test.id
                        var config=configuration(label,at:before,count:2)
                        config["ddlPolicy"]=["triggers":"reject","events":"reject"]
                        let client=try start(test,config); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA")
                        _ = try h.sql("source",session+sql+"; INSERT INTO ddlcompat.t VALUES(1,1)")
                        _ = try finish(client,label,success:false,reason:reason)
                        try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        try require(state(label,"SELECT transactions_applied FROM state")=="0" && state(label,"SELECT COUNT(*) FROM ddl_intents")=="0","rejected policy DDL advanced progress or issued SQL")
                        try require(h.sql("target57","SELECT COUNT(*) FROM ddlcompat.t")=="0","policy rejection applied following DML")
                        try cases.pass(label)
                    }
                    if selection.selects(DDLCompatibilityCases.skipTrigger.id) {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        let test=DDLCompatibilityCases.skipTrigger,before=try h.boundary("source")
                        // No ddlPolicy override: exercise the default skip policy.
                        let client=try start(test,configuration(test.id,at:before,count:8)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA")
                        _ = try h.sql("source",session+"\nDELIMITER $$\nCREATE DEFINER=CURRENT_USER TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW BEGIN SET NEW.n=NEW.n+10; SET NEW.n=NEW.n+1; END$$\nDELIMITER ;")
                        try compatibilityBarrier(client,1)
                        try require(h.sql("native","SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='ddlcompat'")=="1","native did not create the trigger")
                        try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='ddlcompat'")=="0","skip created a target trigger")
                        _ = try h.sql("source","INSERT INTO ddlcompat.t VALUES(1,7),(2,8); DROP TRIGGER ddlcompat.tr; DROP TRIGGER IF EXISTS ddlcompat.tr; INSERT INTO ddlcompat.t VALUES(3,9); CREATE TRIGGER ddlcompat.tr BEFORE UPDATE ON ddlcompat.t FOR EACH ROW SET NEW.n=NEW.n+10; UPDATE ddlcompat.t SET n=20 WHERE id=1; DROP TRIGGER ddlcompat.tr")
                        let result=try finish(client,test.id,success:true),end=try h.boundary("source")
                        try ModifyIndexCases.waitNative(h,end); _ = try h.sql("native","STOP REPLICA")
                        for service in h.services { try require(h.sql(service,"SELECT id,n FROM ddlcompat.t ORDER BY id")=="1\t30\n2\t19\n3\t9","trigger effect was lost or applied twice") }
                        try require(result["appliedGTIDSet"] as? String == end.gtids,"skipped trigger GTIDs were not checkpointed")
                        try require(state(test.id,"SELECT COUNT(*) FROM ddl_skips WHERE reason='ddlPolicy.triggers=skip' AND database_name='ddlcompat' AND object_name='tr'")=="5","missing trigger skip audit")
                        try require(state(test.id,"SELECT COUNT(*) FROM ddl_intents")=="0" && state(test.id,"SELECT COUNT(*) FROM groups WHERE status='APPLIED'")=="8","skipped DDL became a write intent or failed to complete")
                        try require(state(test.id,"SELECT transactions_applied||'|'||rows_applied||'|'||ddl_applied FROM state")=="8|4|0","skip counters differ")
                        try cases.pass(test.id)
                    }
                    if selection.selects(DDLCompatibilityCases.sourceTrigger.id) {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        _ = try h.sql("source","SET SESSION sql_log_bin=0; CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=NEW.n+10")
                        let test=DDLCompatibilityCases.sourceTrigger,before=try h.boundary("source")
                        let client=try start(test,configuration(test.id,at:before,count:1)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA")
                        _ = try h.sql("source","INSERT INTO ddlcompat.t VALUES(1,7)")
                        _ = try finish(client,test.id,success:true); try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        for service in h.services { try require(h.sql(service,"SELECT n FROM ddlcompat.t")=="17","source trigger effect differs") }
                        try cases.pass(test.id)
                    }
                    if selection.selects(DDLCompatibilityCases.generatedMismatch.id) {
                        try resetCompatibility()
                        for service in h.services {
                            let multiplier=service == "target57" ? 3 : 2
                            _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,g INT AS (n*\(multiplier)) STORED)")
                        }
                        let test=DDLCompatibilityCases.generatedMismatch,before=try h.boundary("source")
                        let client=try start(test,configuration(test.id,at:before,count:1)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA"); _ = try h.sql("source","INSERT INTO ddlcompat.t(id,n) VALUES(1,7)")
                        _ = try finish(client,test.id,success:false,reason:"target generated-column values differ")
                        try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        try require(state(test.id,"SELECT transactions_applied FROM state")=="0" && state(test.id,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'")=="1","generated mismatch was completed or lost its uncertain row intent")
                        try cases.pass(test.id)
                    }
                    if selection.selects(DDLCompatibilityCases.targetTrigger.id) {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        _ = try h.sql("target57","SET SESSION sql_log_bin=0; CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=NEW.n+10")
                        let test=DDLCompatibilityCases.targetTrigger,before=try h.boundary("source")
                        let client=try start(test,configuration(test.id,at:before,count:1)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA"); _ = try h.sql("source","INSERT INTO ddlcompat.t VALUES(1,7)")
                        _ = try finish(client,test.id,success:false,reason:"target triggers are unsupported")
                        try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        try require(h.sql("target57","SELECT COUNT(*) FROM ddlcompat.t")=="0","target trigger executed")
                        try cases.pass(test.id)
                    }
                    try resetCompatibility()
                }

                if selection.includes("modify-index") {
                for test in ModifyIndexCases.failures where selection.selects(test.test.id) {
                    let label=test.test.id
                    for service in h.services {
                        let second=test.duplicate && service != "source" ? "seed" : "other"
                        _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi; CREATE TABLE demo.mi(id INT PRIMARY KEY,name VARCHAR(\(test.width)) COLLATE utf8mb4_bin,n INT UNSIGNED,b VARBINARY(8)); INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF),(2,'\(second)',8,NULL)")
                    }
                    let before=try h.boundary("source")
                    let applying=try start(test.test,configuration(label,at:before,count:2));try waitForReader(applying)
                    _ = try h.sql("native","START REPLICA")
                    _ = try h.sql("source",test.sql+"; INSERT INTO demo.mi VALUES(99,'blocked marker',9,NULL)")
                    let diagnostic=try finish(applying,label,success:false,reason:test.error)
                    try require((diagnostic["reason"] as? String)?.hasPrefix("target SQL error ")==true,"index failure was not a target SQL error")
                    let deadline=Date().addingTimeInterval(20)
                    while try h.status()["Last_SQL_Errno"] != test.error && Date()<deadline {Thread.sleep(forTimeInterval:0.1)}
                    try require(h.status()["Last_SQL_Errno"]==test.error,"native error differs from Swift target")
                    let saved=try state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||IFNULL(applied_position,'NULL')||'|'||(active_gtid IS NOT NULL) FROM state")
                    try require(saved=="BLOCKED|0|NULL|1" && state(label,"SELECT status FROM ddl_intents")=="PENDING","failed index lost pending intent or advanced checkpoint")
                    for service in ["native","target57"] {try require(h.sql(service,"SELECT COUNT(*) FROM demo.mi WHERE id=99")=="0","following marker applied after failed index")}
                    try writeJSON(["state":saved,"native":try h.status(),"source_before":before.json,"source_after":try h.boundary("source").json],to:output.appendingPathComponent(label+"-failure.json"))
                    // Fixture reset only: bypass this deliberately rejected range
                    // on the native reference before the next independent case.
                    _ = try h.sql("native","STOP REPLICA")
                    let end=try h.boundary("source")
                    _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(end.file)',SOURCE_LOG_POS=\(end.position)")
                    try cases.pass(label)
                }
                if selection.selects(ModifyIndexCases.timeout.id) {
                    let label=ModifyIndexCases.timeout.id,test=ModifyIndexCases.cases.first{$0.test.id=="ddl-index-create"}!
                    for service in h.services {_ = try h.sql(service,test.seed)}
                    let before=try h.boundary("source")
                    var config=configuration(label,at:before,count:2);config["ddlTimeoutSeconds"]=1
                    let applying=try start(ModifyIndexCases.timeout,config);try waitForReader(applying)
                    _ = try h.sql("native","START REPLICA")
                    let target=try h.compose(["ps","-q","target57"]).text
                    _ = try docker(["exec","-d","-e","MYSQL_PWD=fixture-root-only",target,"mysql","--no-defaults","-uroot","-e","LOCK TABLES demo.mi READ; DO SLEEP(8); UNLOCK TABLES"])
                    let lockDeadline=Date().addingTimeInterval(5)
                    while try h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(8)'") != "1" {
                        try require(Date()<lockDeadline,"test table lock was not acquired");Thread.sleep(forTimeInterval:0.1)
                    }
                    _ = try h.sql("source",test.sql+"; INSERT INTO demo.mi VALUES(99,'blocked marker',9,NULL)")
                    let result=try finish(applying,label,success:false)
                    let failureProgress=result["progress"] as? [String:Any]
                    let failureTrace=(failureProgress?["targetFailure"] as? [String:Any])?["statement"] as? [String:Any]
                    try require(failureTrace?["phase"] as? String == "possiblyExecuted","DDL timeout did not retain uncertain statement phase")
                    try require(state(label,"SELECT lifecycle||'|'||transactions_applied FROM state")=="BLOCKED|0" && state(label,"SELECT status FROM ddl_intents")=="PENDING","DDL timeout lost uncertain intent")
                    let id=try state(label,"SELECT active_gtid FROM state")
                    let refusal=try runner.run(["docker","run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(evidenceVolume),dst=/evidence","--entrypoint","/usr/local/bin/mysql-replicator",image,"skip",id,"--config","/evidence/"+label+".yaml"],checked:false)
                    try require(refusal.status != 0 && String(decoding:refusal.stderr,as:UTF8.self).contains("target write intents"),"uncertain DDL was eligible for skip")
                    let deadline=Date().addingTimeInterval(20)
                    while try h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='apply_fixture' OR INFO='DO SLEEP(8)'") != "0" {
                        try require(Date()<deadline,"timed-out server DDL did not finish after releasing fixture lock");Thread.sleep(forTimeInterval:0.1)
                    }
                    try require(h.sql("target57","SELECT COUNT(*) FROM demo.mi WHERE id=99")=="0","timeout applied following row")
                    try ModifyIndexCases.waitNative(h,h.boundary("source"));_ = try h.sql("native","STOP REPLICA")
                    try writeJSON(result,to:output.appendingPathComponent(label+"-failure.json"));try cases.pass(label)
                }
                for test in ModifyIndexCases.cases where selection.selects(test.test.id) {
                    let label=test.test.id
                    for service in h.services {_ = try h.sql(service,test.seed)}
                    var starts:[String:Boundary]=[:]
                    for service in h.services {starts[service]=try h.boundary(service)}
                    let applying=try start(test.test,configuration(label,at:starts["source"]!,count:1+test.workload.count));try waitForReader(applying)
                    _ = try h.sql("native","START REPLICA")
                    func barrier(_ count:Int) throws {
                        let deadline=Date().addingTimeInterval(30)
                        while Date()<deadline {
                            let logs=try docker(["logs",applying])
                            let last=String(decoding:logs.stdout,as:UTF8.self).split(separator:"\n").last
                            if let last,let progress=try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any],progress["transactionsApplied"] as? Int == count {return}
                            try require(docker(["inspect",applying,"--format","{{.State.Running}}"] ).text == "true","MODIFY/index applier stopped: " + String(decoding:logs.stderr,as:UTF8.self))
                            Thread.sleep(forTimeInterval:0.1)
                        }
                        throw LabError("MODIFY/index did not reach transaction \(count)")
                    }
                    let warnings=try h.sql("source",test.sql+"; SHOW WARNINGS")
                    try require(warnings.isEmpty,"unexpected source warning: \(warnings)")
                    try barrier(1);try ModifyIndexCases.waitNative(h,h.boundary("source"))
                    try cases.assertion("schema-effects",evidence:"assertions/"+label+"/schema-effects.json") {
                        var observed:[String:Any]=["sql":test.sql,"warnings":warnings]
                        for service in h.services {
                            observed[service]=try ModifyIndexCases.metadata(h,service,test)
                            try require(ModifyIndexCases.rows(h,service,test.table)==test.retained,"MODIFY/index changed retained rows")
                        }
                        return observed
                    }
                    if !test.workload.isEmpty {
                    try cases.assertion("following-dml",evidence:"assertions/"+label+"/following-dml.json") {
                        var observed:[[String:Any]]=[]
                        for (index,step) in test.workload.enumerated() {
                            _ = try h.sql("source",step.sql);try barrier(index+2);try ModifyIndexCases.waitNative(h,h.boundary("source"))
                            var item:[String:Any]=["sql":step.sql,"expected":step.rows]
                            for service in h.services {
                                let rows=try ModifyIndexCases.rows(h,service,test.table)
                                try require(rows==step.rows,"\(label) \(service) following rows differ: \(rows)")
                                item[service]=rows
                            }
                            observed.append(item)
                        }
                        return observed
                    }
                    }
                    let result=try finish(applying,label,success:true),end=try h.boundary("source")
                    _ = try h.sql("native","STOP REPLICA")
                    try cases.assertion("source-boundary",evidence:"assertions/"+label+"/source-boundary.json") {
                        try require(result["transactionsApplied"] as? Int == 1+test.workload.count && result["rowsApplied"] as? Int == test.workload.reduce(0,{$0+$1.affectedRows}) && result["ddlApplied"] as? Int == 1 && result["appliedGTIDSet"] as? String == end.gtids,"MODIFY/index counters or GTIDs differ")
                        let saved=try state(label,"SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
                        try require(saved=="STOPPED|\(end.file)|\(end.position)","MODIFY/index checkpoint differs")
                        return ["source":end.json,"saved":saved,"summary":result] as [String:Any]
                    }
                    try cases.assertion("schema-history",evidence:"assertions/"+label+"/schema-history.json") {
                        let intent=try state(label,"SELECT status||'|'||target_sql FROM ddl_intents")
                        try require(intent=="DONE|"+test.sql,"DDL SQL was rewritten or not completed")
                        let references=try state(label,"SELECT COUNT(*) FROM row_intents r JOIN schemas s ON s.id=r.schema_id WHERE s.current=1 AND r.status='DONE'")
                        try require(references==String(test.workload.reduce(0,{$0+$1.affectedRows})),"following rows did not use the published schema")
                        let history=try state(label,"SELECT schema_json FROM schemas WHERE current=1")
                        let schema=try JSONSerialization.jsonObject(with:Data(history.utf8)) as? [String:Any]
                        try require((schema?["columns"] as? [[String:Any]])?.count == 4 && schema?["secondaryIndexes"] is [[String:Any]],"extended schema metadata missing")
                        try require(state(label,"PRAGMA user_version")=="7","extended state lacks current version gate (7)")
                        return ["intent":intent,"schema":schema ?? [:],"following_row_intents":references] as [String:Any]
                    }
                    try cases.assertion("normalized-binlog",evidence:"assertions/"+label+"/normalized-binlog.json") {
                        var observed:[String:[String]]=[:]
                        for service in h.services {
                            let from=starts[service]!,to=try h.boundary(service)
                            try require(from.file==to.file,"unexpected rotation in MODIFY/index comparison")
                            let path=output.appendingPathComponent(service+"-"+label+".binlog")
                            try h.compose(["exec","-T",service,"cat","/var/lib/mysql/"+from.file]).stdout.write(to:path)
                            let decoded=try runner.run([h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv","--start-position=\(from.position)","--stop-position=\(to.position)",path.path])
                            try decoded.stdout.write(to:path.appendingPathExtension("txt"))
                            let lines=String(decoding:decoded.stdout,as:UTF8.self).components(separatedBy:"\n")
                            let normalized=lines.filter{$0.hasPrefix("###") || $0.uppercased().hasPrefix("ALTER TABLE ") || $0.uppercased().hasPrefix("CREATE INDEX ") || $0.uppercased().hasPrefix("CREATE UNIQUE INDEX ") || $0.uppercased().hasPrefix("DROP INDEX ") || $0.uppercased().hasPrefix("CREATE TABLE ") || $0.uppercased().hasPrefix("RENAME TABLE ") || $0.uppercased().hasPrefix("TRUNCATE TABLE ")}.map {line in
                                line.range(of:" /*",options:.backwards).map{String(line[..<$0.lowerBound])} ?? line
                            }
                            try require(normalized.filter{!$0.hasPrefix("###")}.count==1 && normalized.filter{$0.hasPrefix("### INSERT INTO") || $0.hasPrefix("### UPDATE ") || $0.hasPrefix("### DELETE FROM")}.count==test.workload.reduce(0,{$0+$1.affectedRows}),"missing DDL/DML in normalized binlog")
                            if let source=observed["source"] {try require(normalized==source,"\(service) normalized MODIFY/index binlog differs")}
                            observed[service]=normalized
                        }
                        return observed
                    }
                    try cases.pass(label)
                    if label == "ddl-index-create" && selection.selects(ModifyIndexCases.resume.id) {
                        try cases.run(ModifyIndexCases.resume) {
                            let config=configuration(label,at:end,count:1)
                            try writeYAML(config,to:output.appendingPathComponent(label+"-resume.yaml"))
                            _ = try docker(["cp",output.appendingPathComponent(label+"-resume.yaml").path,evidenceHelper+":/evidence/"+label+"-resume.yaml"])
                            let name=h.project+"-indexed-resume";clients.append(name)
                            _ = try docker(["run","-d","--name",name,"--platform","linux/amd64","--network",h.project+"_fixture","--mount","type=volume,src=\(evidenceVolume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator",image,"run","--config","/evidence/"+label+"-resume.yaml"])
                            try waitForReader(name)
                            _ = try h.sql("source","INSERT INTO demo.mi VALUES(4,'resumed',4,NULL)")
                            let resumed=try finish(name,label+"-resume",success:true)
                            try require(resumed["transactionsApplied"] as? Int==5 && resumed["rowsApplied"] as? Int==4 && resumed["ddlApplied"] as? Int==1,"indexed resume reset/replayed counters")
                            try require(ModifyIndexCases.rows(h,"target57",test.table)==test.retained+"\n4\t726573756D6564\t4\tNULL","indexed resume row differs")
                            _ = try h.sql("native","START REPLICA");try ModifyIndexCases.waitNative(h,h.boundary("source"));_ = try h.sql("native","STOP REPLICA")
                            _ = try h.sql("target57","CREATE INDEX external_drift ON demo.mi(n)")
                            let refusal=try runner.run(["docker","run","--rm","--platform","linux/amd64","--network",h.project+"_fixture","--mount","type=volume,src=\(evidenceVolume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator",image,"run","--config","/evidence/"+label+"-resume.yaml"],checked:false)
                            try require(refusal.status != 0 && String(decoding:refusal.stderr,as:UTF8.self).contains("target schema differs from saved checkpoint"),"external index drift was accepted")
                            // The original saved intent/schema evidence above remains
                            // the first run's snapshot; retain the resumed diagnostics separately.
                            try refusal.stderr.write(to:output.appendingPathComponent("indexed-resume-drift.json"))
                        }
                    }
                }
                }
                if selection.includes("database") {
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
                }
                if selection.includes("ordered") {
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
                _ = try finish(missing,"ddl-like-missing-template",success:false,reason:"requires a primary key with 1 to 16 columns")
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
                _ = try h.sql("source","ALTER TABLE poc.items ADD unsupported JSON NULL")
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
                }
            } else if mode == "gtid" && selection.includes("extended") {
                // Additional accepted shapes: multi-row statement and key change.
                let edgeStart = try h.boundary("source"), edgeNativeStart = try h.boundary("native"), edgeTargetStart = try h.boundary("target57")
                let edge = try start(QualificationCase("multirow", "Replicate multirow INSERT and DELETE with a primary-key update"),configuration("multirow",at:edgeStart,count:3)); try waitForReader(edge)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(10,'ten',10),(11,'eleven',18446744073709551615); UPDATE poc.items SET id=12,value='twelve' WHERE id=11; DELETE FROM poc.items WHERE id IN (10,12)")
                let edgeResult = try finish(edge,"multirow",success:true)
                try require(edgeResult["rowsApplied"] as? Int == 5 && h.rows("target57") == Fixture.final,"multirow/key-change application differs")
                let edgeReads = (edgeResult["stageTimings"] as? [String:[String:Any]])?["target.read"]?["count"] as? Int
                try require(edgeReads == 4,"expected three UPDATE/DELETE reads and one new-key absence check")
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
                // The sampled fleet exceeds the former 64-table ceiling.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    let creates = (0..<160).map { "CREATE TABLE poc.capacity_\($0)(id INT PRIMARY KEY,v INT) ENGINE=\(engine)" }.joined(separator:";")
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; "+creates)
                }
                let capacity = try start(QualificationCase("table-capacity", "Discover and apply 160 tables in one session"),configuration("table-capacity",at:try h.boundary("source"),count:160))
                try waitForReader(capacity)
                _ = try h.sql("source",(0..<160).map { "INSERT INTO poc.capacity_\($0) VALUES(1,\($0))" }.joined(separator:";"))
                _ = try finish(capacity,"table-capacity",success:true)
                _ = try h.sql("native","START REPLICA")
                try ModifyIndexCases.waitNative(h,try h.boundary("source"))
                _ = try h.sql("native","STOP REPLICA")
                let capacityRows = (0..<160).map { "SELECT id,v FROM poc.capacity_\($0)" }.joined(separator:" UNION ALL ")
                for service in h.services {
                    try require(h.sql(service,"SELECT COUNT(*),SUM(v) FROM ("+capacityRows+") t") == "160\t12720","many-table rows differ")
                }
                try require(state("table-capacity","SELECT COUNT(*) FROM schemas") == "160","many-table schemas were lost")
                try cases.pass("table-capacity")

                for service in ["native","target57"] {
                    _ = try h.sql(service,"SET GLOBAL default_storage_engine=MyISAM")
                }
                var resumeConfig = configuration("composite-resume",at:try h.boundary("source"),count:2)
                let initial = try start(QualificationCase("composite-resume-initial", "Create and persist a composite primary key at a clean stop"),resumeConfig)
                try waitForReader(initial)
                _ = try h.sql("source","CREATE TABLE poc.composite_resume(id INT,report_date DATE,payload CHAR(4),PRIMARY KEY(report_date,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin; INSERT INTO poc.composite_resume VALUES(7,'2026-01-01','one'),(7,'2026-01-02','two')")
                _ = try finish(initial,"composite-resume-initial",success:true)
                try cases.pass("composite-resume-initial")
                _ = try h.sql("source","ALTER TABLE poc.composite_resume ADD COLUMN score INT NULL; RENAME TABLE poc.composite_resume TO poc.composite_renamed; UPDATE poc.composite_renamed SET report_date='2026-01-03',payload='new' WHERE report_date='2026-01-01' AND id=7; DELETE FROM poc.composite_renamed WHERE report_date='2026-01-02' AND id=7")
                var resumeSource = resumeConfig["source"] as! [String:Any]
                resumeSource["stopAfterTransactions"] = 4; resumeConfig["source"] = resumeSource
                let resumedComposite = try start(QualificationCase("composite-resume", "Resume a composite key through ADD, RENAME and key-changing DML"),resumeConfig,initialize:false)
                _ = try finish(resumedComposite,"composite-resume",success:true)
                _ = try h.sql("native","START REPLICA")
                try ModifyIndexCases.waitNative(h,try h.boundary("source"))
                _ = try h.sql("native","STOP REPLICA")
                for service in h.services {
                    try require(h.sql(service,"SELECT id,report_date,payload,score FROM poc.composite_renamed") == "7\t2026-01-03\tnew\tNULL","composite resume data differs")
                }
                try require(state("composite-resume","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|6|4","composite resume checkpoint differs")
                try cases.pass("composite-resume")
                for service in ["source","target57"] {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.composite_collision(id INT,report_date DATE,v INT,PRIMARY KEY(report_date,id)) ENGINE=\(engine); INSERT INTO poc.composite_collision VALUES(7,'2026-01-01',1)")
                }
                _ = try h.sql("target57","INSERT INTO poc.composite_collision VALUES(7,'2026-01-02',2)")
                let collisionStart = try h.boundary("source")
                _ = try h.sql("source","UPDATE poc.composite_collision SET report_date='2026-01-02' WHERE report_date='2026-01-01' AND id=7")
                let collision = try start(QualificationCase("composite-collision", "Reject a changed composite key occupied by another target row"),configuration("composite-collision",at:collisionStart,count:1))
                _ = try finish(collision,"composite-collision",success:false,reason:"updated primary key already exists")
                try require(h.sql("target57","SELECT report_date,v FROM poc.composite_collision ORDER BY report_date") == "2026-01-01\t1\n2026-01-02\t2","composite collision changed target rows")
                try require(state("composite-collision","SELECT transactions_applied FROM state") == "0","composite collision advanced checkpoint")
                try cases.pass("composite-collision")
                // A dedicated replica retains validated schema across idle lock
                // releases. Local schema changes during apply are unsupported.
                for service in ["source","target57"] {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.epoch(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine)")
                }
                var epochConfig = configuration("schema-cache",at:try h.boundary("source"),count:3)
                var epochTarget = epochConfig["target"] as! [String:Any]
                epochTarget["explicitTableLocks"] = true
                epochConfig["target"] = epochTarget
                let epoch = try start(QualificationCase("schema-cache", "Release idle table locks and reuse validated schema for following writes"),epochConfig)
                try waitForReader(epoch)
                _ = try h.sql("source","INSERT INTO poc.epoch VALUES(1,10)")
                let epochDeadline = Date().addingTimeInterval(15)
                var epochApplied = false
                while Date() < epochDeadline {
                    let log = try docker(["logs",epoch]).stdout
                    if let last = String(decoding:log,as:UTF8.self).split(separator:"\n").last,
                       let progress = try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any],
                       progress["transactionsApplied"] as? Int == 1 { epochApplied = true; break }
                    Thread.sleep(forTimeInterval:0.1)
                }
                try require(epochApplied,"lock fixture did not apply its first group")
                try require(h.sql("target57","SET SESSION lock_wait_timeout=2; SELECT v FROM poc.epoch WHERE id=1") == "10","idle reader could not observe completed group")
                _ = try h.sql("source","UPDATE poc.epoch SET v=20 WHERE id=1; INSERT INTO poc.epoch VALUES(2,30)")
                let epochResult = try finish(epoch,"schema-cache",success:true)
                try require(h.sql("target57","SELECT id,v FROM poc.epoch ORDER BY id") == "1\t20\n2\t30","cached schema writes differ")
                try require(state("schema-cache","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|3|3","cached schema checkpoint differs")
                let epochTimings = epochResult["stageTimings"] as? [String:[String:Any]]
                try require(epochTimings?["target.schema"]?["count"] as? Int == 1,"idle lock reacquisition repeated schema validation")
                try require((epochTimings?["target.lock"]?["count"] as? Int ?? 0) >= 2,"fixture did not reacquire its table lock")
                try require(epochTimings?["target.read"]?["count"] as? Int == 1,"INSERT performed an unnecessary existence read")
                try cases.pass("schema-cache")
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
                    _ = try finish(rejected,label,success:false,reason:label == "absent-schema" ? "requires a primary key" : "signedness")
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
                _ = try finish(partial,"partial",success:false,reason:"1062 (duplicate key)")
                try require(h.sql("target57","SELECT id,value FROM poc.items WHERE id IN (20,21) ORDER BY id") == "20\tfirst\n21\tcollision","partial MyISAM effects differ")
                try require(state("partial","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||COALESCE(applied_position,'NULL') FROM state") == "BLOCKED|0|0|NULL","partial group advanced checkpoint")
                try require(state("partial","SELECT ordinal||'|'||status FROM row_intents ORDER BY ordinal") == "0|PENDING\n1|PENDING","failed INSERT chunk must retain every row as uncertain")
                try cases.pass("partial")
                // Kill a disposable writer after MyISAM has accepted some rows.
                // The whole prepared group must remain unresolved on disk, and
                // ordinary restart must refuse to replay it.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.batch_crash(id INT PRIMARY KEY,v INT NOT NULL) ENGINE=\(engine)")
                }
                let crashStart=try h.boundary("source")
                var crashConfig=configuration("batch-crash",at:crashStart,count:1)
                // Stay below Linux's per-argument limit for mysql -e, while
                // retaining enough SQL chunks to observe and kill mid-group.
                crashConfig["batch"] = ["maximumInsertRows":4]
                let crash=try start(QualificationCase("batch-crash","Kill a writer mid-group and retain all prepared intents without advancing progress"),crashConfig)
                try waitForReader(crash)
                _ = try h.sql("source","INSERT INTO poc.batch_crash VALUES " + (1...8000).map{"(\($0),\($0))"}.joined(separator:","))
                let crashDeadline=Date().addingTimeInterval(30)
                while true {
                    let writes=Int(try h.sql("target57","SELECT COUNT_WRITE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='poc' AND OBJECT_NAME='batch_crash'")) ?? 0
                    if writes > 0 { break }
                    try require(Date() < crashDeadline && docker(["inspect",crash,"--format","{{.State.Running}}"]).text == "true","crash fixture never reached a target write")
                    Thread.sleep(forTimeInterval:0.02)
                }
                _ = try docker(["kill","--signal","KILL",crash])
                try require(docker(["wait",crash]).text == "137","crash fixture did not exit by SIGKILL")
                let crashedLogs=try docker(["logs",crash])
                try crashedLogs.stdout.write(to:output.appendingPathComponent("batch-crash.ndjson"))
                try crashedLogs.stderr.write(to:output.appendingPathComponent("batch-crash.diagnostic.json"))
                let partialRows=Int(try h.sql("target57","SELECT COUNT(*) FROM poc.batch_crash")) ?? -1
                try require((1..<8000).contains(partialRows),"crash did not interrupt a partially applied group")
                try require(state("batch-crash","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||(active_gtid IS NOT NULL) FROM state") == "RUNNING|0|0|1","crash advanced or cleared the pending checkpoint")
                try require(state("batch-crash","SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "8000","crash lost prepared intents or prematurely completed rows")
                try require(state("batch-crash","SELECT COUNT(*) FROM groups WHERE status='PENDING'") == "1","crash lost the pending group")
                try writeJSON(["target_rows_at_crash":partialRows,"prepared_rows":8000,"automatic_replay":false],to:output.appendingPathComponent("batch-crash-evidence.json"))
                try cases.pass("batch-crash")
                let resumed=try start(QualificationCase("batch-crash-resume","Refuse automatic replay of a crashed prepared group"),crashConfig,initialize:false)
                _ = try finish(resumed,"batch-crash-resume",success:false,reason:"cleanly STOPPED")
                try require(h.sql("target57","SELECT COUNT(*) FROM poc.batch_crash") == String(partialRows),"rejected crash resume mutated the target")
                try cases.pass("batch-crash-resume")
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
        stage("PASS: selected \(selection.slice) slice; \(cases.results.count) cases (see selection in result.json)")
    }
}
