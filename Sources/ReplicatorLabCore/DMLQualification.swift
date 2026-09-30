import Foundation

public enum DMLQualification {
    public static func run(root: URL, build: Bool = true) throws {
        let runner = ProcessRunner(root:root)
        let image = "mysql-replicator-packaging:dml"
        if build {
            FileHandle.standardError.write(Data("DML suite: building static Ubuntu image (live build output follows).\n".utf8))
            let result = try runner.run(["docker","build","--progress=plain","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",image,"."],timeout:3600,checked:false,onOutput:{ FileHandle.standardError.write($0) })
            let log = root.appendingPathComponent("artifacts/dml-suite/build-" + runID() + ".log")
            try FileManager.default.createDirectory(at:log.deletingLastPathComponent(),withIntermediateDirectories:true)
            try (result.stdout + result.stderr).write(to:log)
            try require(result.status == 0,"DML image build failed; see \(log.path)")
        }
        let qualifiedImage = try runner.run(["docker","image","inspect",image,"--format","{{.Id}}"]).text
        for mode in ["file-position","gtid"] { try runCase(root:root,image:qualifiedImage,mode:mode) }
    }
    private static func runCase(root: URL,image: String,mode: String) throws {
        var native = NativeCase(); native.transaction = false; native.autoPosition = mode == "gtid"
        let h = NativeHarness(root:root,config:native,artifactCategory:"dml-suite")
        let runner = h.runner, output = h.output, tls = output.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at:tls,withIntermediateDirectories:true)
        h.composeOverlays = [root.appendingPathComponent("docker/dml/compose.yaml").path]
        let evidenceVolume = h.project + "-evidence", evidenceHelper = h.project + "-evidence-copy"
        h.composeEnvironment = ["REPLICATOR_DML_EVIDENCE_VOLUME":evidenceVolume]
        var volumeCreated = false, helperCreated = false
        var copiedStates: Set<String> = []
        var clients: [String] = [], started = false, failure: Error?
        var report: [String:Any] = ["schema_version":1,"result":"failed","mode":mode,"automatic_recovery":false,"ddl":"unsupported"]
        func stage(_ text: String) { FileHandle.standardError.write(Data(("DML \(mode): " + text + "\n").utf8)) }
        stage("evidence: \(output.path)")
        func docker(_ args: [String]) throws -> CommandResult { try runner.run(["docker"] + args) }
        func record(_ name: String,_ args: [String]) throws -> CommandResult {
            let r = try runner.run(args,checked:false)
            try r.stdout.write(to:output.appendingPathComponent(name + ".stdout")); try r.stderr.write(to:output.appendingPathComponent(name + ".stderr"))
            try require(r.status == 0,"\(name) failed; see evidence")
            return r
        }
        func start(_ label: String,_ config: [String:Any]) throws -> String {
            stage("starting \(label)")
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
            stage("passed \(label)")
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
                let engine = service == "source" ? "InnoDB" : "MyISAM"
                _ = try h.sql(service,"CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(engine); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)")
            }
            _ = try h.sql("target57","CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER ON poc.* TO 'apply_fixture'@'%'; GRANT REPLICATION CLIENT,SUPER ON *.* TO 'apply_fixture'@'%'; GRANT SELECT ON performance_schema.* TO 'apply_fixture'@'%'")
            let uuid = try h.sql("source","SELECT @@server_uuid"), targetUUID = try h.sql("target57","SELECT @@server_uuid")
            let sourceStart = try h.boundary("source"), nativeStart = try h.boundary("native"), targetStart = try h.boundary("target57")
            let clause: String
            if mode == "gtid" { _ = try h.sql("native","SET @@GLOBAL.gtid_purged='+\(sourceStart.gtids)'"); clause = "SOURCE_AUTO_POSITION=1" }
            else { clause = "SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(sourceStart.file)',SOURCE_LOG_POS=\(sourceStart.position)" }
            _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='native_fixture',SOURCE_PASSWORD='fixture-native-only',SOURCE_SSL=1,\(clause); START REPLICA")
            func configuration(_ label: String,at boundary: Boundary,count: Int) -> [String:Any] {
                var start: [String:Any] = ["executedGTIDs":boundary.gtids]
                if mode == "file-position" { start["file"] = boundary.file; start["position"] = boundary.position }
                let source: [String:Any] = ["version":1,"host":"source","port":3306,"username":"capture_fixture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem","serverID":9100,"sourceUUID":uuid,"mode":mode,"start":start,"tables":[["database":"poc","table":"items","columns":["signed","utf8","unsigned"]]],"stopAfterTransactions":count]
                let columns: [[String:Any]] = [["name":"id","type":"int","nullable":false],["name":"value","type":"varchar(100)","nullable":false,"collation":"utf8mb4_unicode_ci"],["name":"quantity","type":"bigint unsigned","nullable":false]]
                return ["version":1,"source":source,"target":["host":"target57","port":3306,"username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","serverHostname":"target57","caFile":"/evidence/tls/ca.pem","nativeAutoStartDisabled":true,"targetUUID":targetUUID],"tables":[["database":"poc","table":"items","primaryKey":"id","columns":columns]],"stateDirectory":"/evidence/state-" + label]
            }
            let positiveConfig = configuration("positive",at:sourceStart,count:4)
            let client = try start("positive",positiveConfig); try waitForReader(client)
            stage("running INSERT/UPDATE/DELETE workload")
            _ = try h.sql("source",Fixture.sql(transaction:false))
            let sourceEnd = try h.boundary("source")
            let positive = try finish(client,"positive",success:true)
            try require(positive["transactionsApplied"] as? Int == 4 && positive["rowsApplied"] as? Int == 4,"wrong applied counters")
            let reached = try h.sql("native","SELECT SOURCE_POS_WAIT('\(sourceEnd.file)',\(sourceEnd.position),30)")
            try require(reached != "NULL" && reached != "-1","native did not converge")
            for service in h.services { try require(h.rows(service) == Fixture.final,"\(service) rows differ") }
            try require(h.sql("target57","SELECT @@GLOBAL.gtid_executed").isEmpty,"Swift injected source GTIDs into target")
            try require(state("positive","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||applied_position||'|'||applied_gtids FROM state") == "STOPPED|4|4|\(sourceEnd.position)|\(sourceEnd.gtids)","SQLite applied checkpoint differs")
            try require(state("positive","SELECT COUNT(*) FROM row_intents WHERE status='DONE'") == "4","missing completed row intents")
            _ = try h.sql("native","STOP REPLICA")
            let nativeEnd = try h.boundary("native"), targetEnd = try h.boundary("target57")
            for (service,from,to) in [("source",sourceStart,sourceEnd),("native",nativeStart,nativeEnd),("target57",targetStart,targetEnd)] {
                try Comparison.operations(h.capture(service,start:from,end:to),expected:Fixture.operations)
                let dir = output.appendingPathComponent(service)
                try FileManager.default.copyItem(at:dir.appendingPathComponent("operations.json"),to:dir.appendingPathComponent("positive-operations.json"))
            }
            report["positive"] = positive
            if mode == "gtid" {
                // Additional accepted shapes: multi-row statement and key change.
                let edgeStart = try h.boundary("source"), edgeNativeStart = try h.boundary("native"), edgeTargetStart = try h.boundary("target57")
                let edge = try start("multirow",configuration("multirow",at:edgeStart,count:3)); try waitForReader(edge)
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
                // Exact wire/bind values get an independent HEX-based SQL oracle;
                // the mysqlbinlog text normalizer deliberately covers only items.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.exact_values(id BIGINT PRIMARY KEY,u INT UNSIGNED NOT NULL,b BIGINT UNSIGNED NOT NULL,t VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL,v VARBINARY(100) NULL) ENGINE=\(engine)")
                }
                var exactConfig = configuration("exact-values",at:try h.boundary("source"),count:3)
                var exactSource = exactConfig["source"] as! [String:Any]
                exactSource["tables"] = [["database":"poc","table":"exact_values","columns":["signed","unsigned","unsigned","utf8","binary"]]]
                exactConfig["source"] = exactSource
                exactConfig["tables"] = [["database":"poc","table":"exact_values","primaryKey":"id","columns":[["name":"id","type":"bigint","nullable":false],["name":"u","type":"int unsigned","nullable":false],["name":"b","type":"bigint unsigned","nullable":false],["name":"t","type":"varchar(100)","nullable":true,"collation":"utf8mb4_bin"],["name":"v","type":"varbinary(100)","nullable":true]]]]
                let exact = try start("exact-values",exactConfig); try waitForReader(exact)
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
                report["exact_values"] = "integer_extremes_utf8_binary_null_empty_passed"
                // Existing state is never silently reset or used for an unsafe replay.
                _ = try finish(start("existing",positiveConfig),"existing",success:false,reason:"state directory must be new")
                // Before-image mismatch must publish no applied transaction.
                _ = try h.sql("target57","UPDATE poc.items SET value='drift' WHERE id=1")
                let beforeMismatch = try h.rows("target57")
                let mismatch = try start("mismatch",configuration("mismatch",at:try h.boundary("source"),count:1)); try waitForReader(mismatch)
                _ = try h.sql("source","UPDATE poc.items SET value='next' WHERE id=1")
                _ = try finish(mismatch,"mismatch",success:false,reason:"before-image mismatch")
                try require(h.rows("target57") == beforeMismatch && state("mismatch","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "BLOCKED|0|0","mismatch mutated or advanced target")
                _ = try h.sql("target57","UPDATE poc.items SET value='next' WHERE id=1")
                // Native's known multi-statement MyISAM rejection: Swift is
                // allowed to reject the shape before its first target write.
                let rejectedRows = try h.rows("target57")
                let multiple = try start("multistatement",configuration("multistatement",at:try h.boundary("source"),count:1)); try waitForReader(multiple)
                _ = try h.sql("native","START REPLICA")
                _ = try h.sql("source","BEGIN; INSERT INTO poc.items VALUES(99,'reject',99); UPDATE poc.items SET value='not-applied' WHERE id=1; COMMIT")
                _ = try finish(multiple,"multistatement",success:false,reason:"single-statement")
                let failedEnd = try h.boundary("source")
                _ = try h.sql("native","SELECT SOURCE_POS_WAIT('\(failedEnd.file)',\(failedEnd.position),10)")
                try require(h.status()["Last_SQL_Errno"] == "1837","native rejection differs")
                try require(h.rows("target57") == rejectedRows && state("multistatement","SELECT transactions_applied FROM state") == "0","unsupported group partially applied")
                _ = try h.sql("native","STOP REPLICA")
                // Native channel exclusion is checked even before source capture.
                _ = try h.sql("target57","CHANGE MASTER TO MASTER_HOST='source',MASTER_USER='invalid-fixture',MASTER_PASSWORD='invalid',MASTER_CONNECT_RETRY=1,MASTER_SSL=1; START SLAVE IO_THREAD")
                _ = try finish(start("native-channel",configuration("native-channel",at:try h.boundary("source"),count:1)),"native-channel",success:false,reason:"native replication channel")
                _ = try h.sql("target57","STOP SLAVE; RESET SLAVE ALL")
                _ = try h.sql("target57","CREATE TRIGGER poc.reject_trigger BEFORE INSERT ON poc.items FOR EACH ROW SET NEW.value='trigger'")
                _ = try finish(start("trigger",configuration("trigger",at:try h.boundary("source"),count:1)),"trigger",success:false,reason:"triggers are unsupported")
                _ = try h.sql("target57","DROP TRIGGER poc.reject_trigger")
                try require(h.rows("target57") == rejectedRows,"preflight rejection changed rows")
                // A later row error cannot roll back an earlier MyISAM write.
                _ = try h.sql("target57","INSERT INTO poc.items VALUES(21,'collision',21)")
                let partial = try start("partial",configuration("partial",at:try h.boundary("source"),count:1)); try waitForReader(partial)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(20,'first',20),(21,'second',21)")
                _ = try finish(partial,"partial",success:false,reason:"primary key already exists")
                try require(h.sql("target57","SELECT id,value FROM poc.items WHERE id IN (20,21) ORDER BY id") == "20\tfirst\n21\tcollision","partial MyISAM effects differ")
                try require(state("partial","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||COALESCE(applied_position,'NULL') FROM state") == "BLOCKED|0|0|NULL","partial group advanced checkpoint")
                try require(state("partial","SELECT ordinal||'|'||status FROM row_intents ORDER BY ordinal") == "0|DONE\n1|PENDING","partial row intents differ")
                // Missing DELETE row is an error, not an idempotent success.
                _ = try h.sql("target57","DELETE FROM poc.items WHERE id=3")
                let missing = try start("missing",configuration("missing",at:try h.boundary("source"),count:1)); try waitForReader(missing)
                _ = try h.sql("source","DELETE FROM poc.items WHERE id=3")
                _ = try finish(missing,"missing",success:false,reason:"missing row")
                try require(state("missing","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","missing delete advanced checkpoint")
                report["negative_checks"] = ["existing_state","before_image_mismatch","multistatement_native_1837","native_channel","trigger","partial_multirow","missing_delete"]
                report["extended_dml"] = "multirow_insert_delete_and_primary_key_update_passed"
            }
        } catch { failure = error; report["error"] = String(describing:error) }
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
        if let failure { throw LabError("\(failure); evidence: \(output.path)") }
        stage("PASS: DML data, binlogs and applied checkpoints")
    }
}
