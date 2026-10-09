import Foundation

extension SharedCorrectness.Run {
    /// Engine-specific contract: partial MyISAM persistence and refused replay.
    /// The InnoDB recovery suite has different rollback/retry expectations.
    func myisamRecovery() throws {
        guard f.profile == .forward && selects("myisam-recovery") else { return }
        try resetNativeEngine()
        try f.awaitNative()
        let h=f.h, isolated=LabIsolatedApply(f)
        var report: [String:Any] = [:]
        var configs: [String:[String:Any]] = [:]
        var snapshots=Set<String>()
        func docker(_ args: [String]) throws -> CommandResult { try f.docker(args) }
        func configuration(_ label: String, at boundary: Boundary, count: Int) -> [String:Any] {
            isolated.configuration(label,at:boundary,count:count)
        }
        func start(_ test: QualificationCase, _ config: [String:Any], initialize: Bool = true) throws -> String {
            try reporter.begin(test); configs[test.id]=config
            return try isolated.start(test.id,config:config,initialize:initialize)
        }
        func finish(_ name: String, _ label: String, success: Bool, reason: String? = nil) throws -> [String:Any] {
            try isolated.finish(name,label:label,config:configs[label]!,success:success,reason:reason)
        }
        func state(_ label: String, _ sql: String) throws -> String {
            // SIGKILL and init refusal do not have normal finish snapshots.
            if snapshots.insert(label).inserted {
                let destination=f.output.appendingPathComponent("recovery-state-"+label)
                _ = try docker(["cp",f.helper+":"+(configs[label]!["stateDirectory"] as! String),destination.path])
            }
            return try f.runner.run(["sqlite3",f.output.appendingPathComponent("recovery-state-"+label+"/state.sqlite").path,sql]).text
        }
        func waitForReader(_ client: String) throws {
            let deadline=Date().addingTimeInterval(30)
            repeat {
                if try f.sql(.source,"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'") == "1" { return }
                try require(docker(["inspect",client,"--format","{{.State.Running}}"] ).text == "true","recovery writer stopped before capture")
                Thread.sleep(forTimeInterval:0.1)
            } while Date()<deadline
            throw LabError("recovery capture did not start")
        }
        try reporter.run(QualificationCase("myisam-recovery","MyISAM discovery, exact values, cache, failures and crash/replay refusal")) {
            for service in h.services {
                let engine=service == "source" ? "InnoDB" : "MyISAM"
                _ = try h.sql(service,"SET sql_log_bin=0; DROP DATABASE IF EXISTS poc; CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(engine); INSERT INTO poc.items VALUES(1,'updated',1),(3,'final-three',18446744073709551615)")
            }
            _ = try h.sql("native","STOP REPLICA")
            // Existing-state refusal reuses this clean initialized checkpoint.
            // It is separate from the independently qualified basic DML oracle.
            for service in h.services { _ = try h.sql(service,"SET sql_log_bin=0; CREATE TABLE poc.recovery_marker(id INT PRIMARY KEY)") }
            let positiveConfig=configuration("recovery-existing",at:try f.boundary(),count:1)
            let initialized=try isolated.start("recovery-existing",config:positiveConfig)
            _ = try h.sql("source","INSERT INTO poc.recovery_marker VALUES(1)")
            _ = try isolated.finish(initialized,label:"recovery-existing",config:positiveConfig)
            _ = try h.sql("native","START REPLICA"); try f.awaitNative(); _ = try h.sql("native","STOP REPLICA")
                // Additional accepted shapes: multi-row statement and key change.
                let edgeStart = try h.boundary("source"), edgeNativeStart = try h.boundary("native"), edgeTargetStart = try h.boundary("target57")
                let edge = try start(SharedWorkflowCases.recovery("multirow"),configuration("multirow",at:edgeStart,count:3)); try waitForReader(edge)
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
                    let dir = f.output.appendingPathComponent(service)
                    try FileManager.default.copyItem(at:dir.appendingPathComponent("operations.json"),to:dir.appendingPathComponent("multirow-operations.json"))
                }
                try reporter.pass("multirow")
                // Exact wire/bind values get an independent HEX-based SQL oracle;
                // the mysqlbinlog text normalizer deliberately covers only items.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.exact_values(id BIGINT PRIMARY KEY,u INT UNSIGNED NOT NULL,b BIGINT UNSIGNED NOT NULL,t VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL,v VARBINARY(100) NULL) ENGINE=\(engine)")
                }
                let exactConfig = configuration("exact-values",at:try h.boundary("source"),count:3)
                let exact = try start(SharedWorkflowCases.recovery("exact-values"),exactConfig); try waitForReader(exact)
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
                        try actual.write(to:f.output.appendingPathComponent("\(service)-exact-\(count).tsv"),atomically:true,encoding:.utf8)
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
                try reporter.pass("exact-values")
                report["exact_values"] = "integer_extremes_utf8_binary_null_empty_passed"
                // One process discovers two new names and a non-leading key.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.ordered_a(payload VARCHAR(30) NULL,k BIGINT UNSIGNED PRIMARY KEY) ENGINE=\(engine); CREATE TABLE poc.ordered_b(flag INT NOT NULL,blob_value VARBINARY(10) NULL,k INT PRIMARY KEY) ENGINE=\(engine)")
                }
                let discovery=try start(SharedWorkflowCases.recovery("discovery"),configuration("discovery",at:try h.boundary("source"),count:4)); try waitForReader(discovery)
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
                try reporter.pass("discovery")
                report["automatic_discovery"]="multiple_tables_nonleading_keys"
                // The sampled fleet exceeds the former 64-table ceiling.
                for service in h.services {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    let creates = (0..<160).map { "CREATE TABLE poc.capacity_\($0)(id INT PRIMARY KEY,v INT) ENGINE=\(engine)" }.joined(separator:";")
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; "+creates)
                }
                let capacity = try start(SharedWorkflowCases.recovery("table-capacity"),configuration("table-capacity",at:try h.boundary("source"),count:160))
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
                try reporter.pass("table-capacity")

                for service in ["native","target57"] {
                    _ = try h.sql(service,"SET GLOBAL default_storage_engine=MyISAM")
                }
                var resumeConfig = configuration("composite-resume",at:try h.boundary("source"),count:2)
                let initial = try start(SharedWorkflowCases.recovery("composite-resume-initial"),resumeConfig)
                try waitForReader(initial)
                _ = try h.sql("source","CREATE TABLE poc.composite_resume(id INT,report_date DATE,payload CHAR(4),PRIMARY KEY(report_date,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin; INSERT INTO poc.composite_resume VALUES(7,'2026-01-01','one'),(7,'2026-01-02','two')")
                _ = try finish(initial,"composite-resume-initial",success:true)
                try reporter.pass("composite-resume-initial")
                _ = try h.sql("source","ALTER TABLE poc.composite_resume ADD COLUMN score INT NULL; RENAME TABLE poc.composite_resume TO poc.composite_renamed; UPDATE poc.composite_renamed SET report_date='2026-01-03',payload='new' WHERE report_date='2026-01-01' AND id=7; DELETE FROM poc.composite_renamed WHERE report_date='2026-01-02' AND id=7")
                var resumeSource = resumeConfig["source"] as! [String:Any]
                resumeSource["stopAfterTransactions"] = 4; resumeConfig["source"] = resumeSource
                let resumedComposite = try start(SharedWorkflowCases.recovery("composite-resume"),resumeConfig,initialize:false)
                _ = try finish(resumedComposite,"composite-resume",success:true)
                _ = try h.sql("native","START REPLICA")
                try ModifyIndexCases.waitNative(h,try h.boundary("source"))
                _ = try h.sql("native","STOP REPLICA")
                for service in h.services {
                    try require(h.sql(service,"SELECT id,report_date,payload,score FROM poc.composite_renamed") == "7\t2026-01-03\tnew\tNULL","composite resume data differs")
                }
                try require(state("composite-resume","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "STOPPED|6|4","composite resume checkpoint differs")
                try reporter.pass("composite-resume")
                for service in ["source","target57"] {
                    let engine = service == "source" ? "InnoDB" : "MyISAM"
                    _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE poc.composite_collision(id INT,report_date DATE,v INT,PRIMARY KEY(report_date,id)) ENGINE=\(engine); INSERT INTO poc.composite_collision VALUES(7,'2026-01-01',1)")
                }
                _ = try h.sql("target57","INSERT INTO poc.composite_collision VALUES(7,'2026-01-02',2)")
                let collisionStart = try h.boundary("source")
                _ = try h.sql("source","UPDATE poc.composite_collision SET report_date='2026-01-02' WHERE report_date='2026-01-01' AND id=7")
                let collision = try start(SharedWorkflowCases.recovery("composite-collision"),configuration("composite-collision",at:collisionStart,count:1))
                _ = try finish(collision,"composite-collision",success:false,reason:"updated primary key already exists")
                try require(h.sql("target57","SELECT report_date,v FROM poc.composite_collision ORDER BY report_date") == "2026-01-01\t1\n2026-01-02\t2","composite collision changed target rows")
                try require(state("composite-collision","SELECT transactions_applied FROM state") == "0","composite collision advanced checkpoint")
                try reporter.pass("composite-collision")
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
                let epoch = try start(SharedWorkflowCases.recovery("schema-cache"),epochConfig)
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
                try reporter.pass("schema-cache")
                for test in [
                    SharedWorkflowCases.recovery("absent-schema"),
                    SharedWorkflowCases.recovery("incompatible-schema")
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
                    try reporter.pass(label)
                }
                // Existing state is never silently reset or used for an unsafe replay.
                _ = try finish(start(SharedWorkflowCases.recovery("existing"),positiveConfig),"existing",success:false,reason:"state directory must be new")
                try reporter.pass("existing")
                let afterSchemaFailures=try h.boundary("source")
                _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(afterSchemaFailures.file)',SOURCE_LOG_POS=\(afterSchemaFailures.position)")
                // Before-image mismatch must publish no applied transaction.
                _ = try h.sql("target57","UPDATE poc.items SET value='drift' WHERE id=1")
                let beforeMismatch = try h.rows("target57")
                let mismatch = try start(SharedWorkflowCases.recovery("mismatch"),configuration("mismatch",at:try h.boundary("source"),count:1)); try waitForReader(mismatch)
                _ = try h.sql("source","UPDATE poc.items SET value='next' WHERE id=1")
                _ = try finish(mismatch,"mismatch",success:false,reason:"before-image mismatch")
                try require(h.rows("target57") == beforeMismatch && state("mismatch","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "BLOCKED|0|0","mismatch mutated or advanced target")
                try reporter.pass("mismatch")
                _ = try h.sql("target57","UPDATE poc.items SET value='next' WHERE id=1")
                // Native's known multi-statement MyISAM rejection: Swift is
                // allowed to reject the shape before its first target write.
                let rejectedRows = try h.rows("target57")
                let multiple = try start(SharedWorkflowCases.recovery("multistatement"),configuration("multistatement",at:try h.boundary("source"),count:1)); try waitForReader(multiple)
                _ = try h.sql("native","START REPLICA")
                _ = try h.sql("source","BEGIN; INSERT INTO poc.items VALUES(99,'reject',99); UPDATE poc.items SET value='not-applied' WHERE id=1; COMMIT")
                _ = try finish(multiple,"multistatement",success:false,reason:"single-statement")
                let failedEnd = try h.boundary("source")
                _ = try h.sql("native","SELECT SOURCE_POS_WAIT('\(failedEnd.file)',\(failedEnd.position),10)")
                try require(h.status()["Last_SQL_Errno"] == "1837","native rejection differs")
                try require(h.rows("target57") == rejectedRows && state("multistatement","SELECT transactions_applied FROM state") == "0","unsupported group partially applied")
                _ = try h.sql("native","STOP REPLICA")
                try reporter.pass("multistatement")
                // Native channel exclusion is checked even before source capture.
                _ = try h.sql("target57","CHANGE MASTER TO MASTER_HOST='source',MASTER_USER='invalid-fixture',MASTER_PASSWORD='invalid',MASTER_CONNECT_RETRY=1,MASTER_SSL=1; START SLAVE IO_THREAD")
                _ = try finish(start(SharedWorkflowCases.recovery("native-channel"),configuration("native-channel",at:try h.boundary("source"),count:1)),"native-channel",success:false,reason:"native replication channel")
                try reporter.pass("native-channel")
                _ = try h.sql("target57","STOP SLAVE; RESET SLAVE ALL")
                _ = try h.sql("target57","CREATE TRIGGER poc.reject_trigger BEFORE INSERT ON poc.items FOR EACH ROW SET NEW.value='trigger'")
                let trigger = try start(SharedWorkflowCases.recovery("trigger"),configuration("trigger",at:try h.boundary("source"),count:1)); try waitForReader(trigger)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(88,'trigger-rejected',88)")
                _ = try finish(trigger,"trigger",success:false,reason:"triggers are unsupported")
                _ = try h.sql("target57","DROP TRIGGER poc.reject_trigger")
                try require(h.rows("target57") == rejectedRows,"preflight rejection changed rows")
                try reporter.pass("trigger")
                // A later row error cannot roll back an earlier MyISAM write.
                _ = try h.sql("target57","INSERT INTO poc.items VALUES(21,'collision',21)")
                let partial = try start(SharedWorkflowCases.recovery("partial"),configuration("partial",at:try h.boundary("source"),count:1)); try waitForReader(partial)
                _ = try h.sql("source","INSERT INTO poc.items VALUES(20,'first',20),(21,'second',21)")
                _ = try finish(partial,"partial",success:false,reason:"1062 (duplicate key)")
                try require(h.sql("target57","SELECT id,value FROM poc.items WHERE id IN (20,21) ORDER BY id") == "20\tfirst\n21\tcollision","partial MyISAM effects differ")
                try require(state("partial","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||COALESCE(applied_position,'NULL') FROM state") == "BLOCKED|0|0|NULL","partial group advanced checkpoint")
                try require(state("partial","SELECT ordinal||'|'||status FROM row_intents ORDER BY ordinal") == "0|PENDING\n1|PENDING","failed INSERT chunk must retain every row as uncertain")
                try reporter.pass("partial")
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
                let crash=try start(SharedWorkflowCases.recovery("batch-crash"),crashConfig)
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
                try crashedLogs.stdout.write(to:f.output.appendingPathComponent("batch-crash.ndjson"))
                try crashedLogs.stderr.write(to:f.output.appendingPathComponent("batch-crash.diagnostic.json"))
                let partialRows=Int(try h.sql("target57","SELECT COUNT(*) FROM poc.batch_crash")) ?? -1
                try require((1..<8000).contains(partialRows),"crash did not interrupt a partially applied group")
                try require(state("batch-crash","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||(active_gtid IS NOT NULL) FROM state") == "RUNNING|0|0|1","crash advanced or cleared the pending checkpoint")
                try require(state("batch-crash","SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "8000","crash lost prepared intents or prematurely completed rows")
                try require(state("batch-crash","SELECT COUNT(*) FROM groups WHERE status='PENDING'") == "1","crash lost the pending group")
                try writeJSON(["target_rows_at_crash":partialRows,"prepared_rows":8000,"automatic_replay":false],to:f.output.appendingPathComponent("batch-crash-evidence.json"))
                try reporter.pass("batch-crash")
                let resumed=try start(SharedWorkflowCases.recovery("batch-crash-resume"),crashConfig,initialize:false)
                _ = try finish(resumed,"batch-crash-resume",success:false,reason:"cleanly STOPPED")
                try require(h.sql("target57","SELECT COUNT(*) FROM poc.batch_crash") == String(partialRows),"rejected crash resume mutated the target")
                try reporter.pass("batch-crash-resume")
                // Missing DELETE row is an error, not an idempotent success.
                _ = try h.sql("target57","DELETE FROM poc.items WHERE id=3")
                let missing = try start(SharedWorkflowCases.recovery("missing"),configuration("missing",at:try h.boundary("source"),count:1)); try waitForReader(missing)
                _ = try h.sql("source","DELETE FROM poc.items WHERE id=3")
                _ = try finish(missing,"missing",success:false,reason:"missing row")
                try require(state("missing","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","missing delete advanced checkpoint")
                try reporter.pass("missing")
                report["negative_checks"] = ["existing_state","before_image_mismatch","multistatement_native_1837","native_channel","trigger","partial_multirow","missing_delete"]
                report["extended_dml"] = "multirow_insert_delete_and_primary_key_update_passed"
            try SharedWorkflowCases.requirePassed(SharedWorkflowCases.recovery,in:reporter.results)
            try writeJSON(report,to:f.output.appendingPathComponent("myisam-recovery.json"))
        }
    }
}
