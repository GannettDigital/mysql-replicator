import Foundation

extension SharedCorrectness.Run {
    /// Historical forward failure contracts: deliberately divergent snapshots,
    /// MyISAM index limits and native error codes. Kept separate from InnoDB cases.
    func forwardFailures() throws {
        guard f.profile == .forward && selects("forward-failures") else { return }
        try resetNativeEngine(); try f.awaitNative()
        let h=f.h, runner=f.runner, image=f.image, evidenceVolume=f.volume
        let isolated=LabIsolatedApply(f)
        var configs: [String:[String:Any]] = [:]
        let bootstrapTriggerSkip=SharedWorkflowCases.bootstrapTriggerSkip
        func docker(_ args: [String]) throws -> CommandResult { try f.docker(args) }
        func configuration(_ label: String, at boundary: Boundary, count: Int) -> [String:Any] { isolated.configuration(label,at:boundary,count:count) }
        func start(_ test: QualificationCase, _ config: [String:Any], initialize: Bool = true) throws -> String {
            try reporter.begin(test); configs[test.id]=config
            return try isolated.start(test.id,config:config,initialize:initialize)
        }
        func finish(_ name: String, _ label: String, success: Bool, reason: String? = nil) throws -> [String:Any] {
            try isolated.finish(name,label:label,config:configs[label]!,success:success,reason:reason)
        }
        func state(_ label: String, _ sql: String) throws -> String { try isolated.state(label,sql) }
        func waitForReader(_ client: String) throws {
            try isolated.waitForReader(client)
        }
        func compatibilityBarrier(_ client: String, _ count: Int) throws { try isolated.barrier(client,count:count); try ModifyIndexCases.waitNative(h,h.boundary("source")) }
        func resetCompatibility() throws {
            _ = try h.sql("native","STOP REPLICA")
            for service in h.services { _ = try h.sql(service,"SET sql_log_bin=0; DROP DATABASE IF EXISTS ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin") }
        }
        try reporter.run(QualificationCase("forward-failures","Forward DDL/policy failures retain diagnostics, pending evidence and blocked following writes")) {
            // Use the legacy restricted grants. Global CREATE would make the
            // permission-denied fixtures silently test a different condition.
            _ = try h.sql("target57","REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'apply_fixture'@'%'; GRANT REPLICATION CLIENT,SUPER ON *.* TO 'apply_fixture'@'%'; GRANT SELECT ON performance_schema.* TO 'apply_fixture'@'%'")
            for database in ["poc","otherdb","demo","ddlcompat"] {
                _ = try h.sql("target57","GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP,INDEX,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,EXECUTE ON \(database).* TO 'apply_fixture'@'%'")
            }
            for service in h.services {
                _ = try h.sql(service,"SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS poc.items; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL); INSERT INTO poc.items VALUES(1,'updated',1),(3,'final-three',18446744073709551615)")
            }
                    for (test,sql,reason) in [
                        (DDLCompatibilityCases.trigger,"CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=7","DDL policy rejects triggers"),
                        (DDLCompatibilityCases.event,"CREATE EVENT ddlcompat.e ON SCHEDULE EVERY 1 DAY DISABLE DO INSERT INTO ddlcompat.t VALUES(99,99)","DDL policy rejects events")
                    ] {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        let before=try h.boundary("source"),label=test.id
                        var config=configuration(label,at:before,count:2)
                        config["ddlPolicy"]=["triggers":"reject","events":"reject"]
                        let client=try start(test,config)
                        // Both readers deliberately use the same MySQL account.
                        // Readiness must identify this client, not count readers.
                        _ = try h.sql("native","START REPLICA")
                        try waitForReader(client)
                        _ = try h.sql("source",session+sql+"; INSERT INTO ddlcompat.t VALUES(1,1)")
                        _ = try finish(client,label,success:false,reason:reason)
                        try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        try require(state(label,"SELECT transactions_applied FROM state")=="0" && state(label,"SELECT COUNT(*) FROM ddl_intents")=="0","rejected policy DDL advanced progress or issued SQL")
                        try require(h.sql("target57","SELECT COUNT(*) FROM ddlcompat.t")=="0","policy rejection applied following DML")
                        try reporter.pass(label)
                    }
                    do {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        let test=bootstrapTriggerSkip,before=try h.boundary("source")
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
                        try reporter.pass(test.id)
                    }
                    do {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        _ = try h.sql("source","SET SESSION sql_log_bin=0; CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=NEW.n+10")
                        let test=DDLCompatibilityCases.sourceTrigger,before=try h.boundary("source")
                        let client=try start(test,configuration(test.id,at:before,count:1)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA")
                        _ = try h.sql("source","INSERT INTO ddlcompat.t VALUES(1,7)")
                        _ = try finish(client,test.id,success:true); try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        for service in h.services { try require(h.sql(service,"SELECT n FROM ddlcompat.t")=="17","source trigger effect differs") }
                        try reporter.pass(test.id)
                    }
                    do {
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
                        try reporter.pass(test.id)
                    }
                    do {
                        try resetCompatibility()
                        for service in h.services { _ = try h.sql(service,"SET SESSION sql_log_bin=0; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)") }
                        _ = try h.sql("target57","SET SESSION sql_log_bin=0; CREATE TRIGGER ddlcompat.tr BEFORE INSERT ON ddlcompat.t FOR EACH ROW SET NEW.n=NEW.n+10")
                        let test=DDLCompatibilityCases.targetTrigger,before=try h.boundary("source")
                        let client=try start(test,configuration(test.id,at:before,count:1)); try waitForReader(client)
                        _ = try h.sql("native","START REPLICA"); _ = try h.sql("source","INSERT INTO ddlcompat.t VALUES(1,7)")
                        _ = try finish(client,test.id,success:false,reason:"target triggers are unsupported")
                        try ModifyIndexCases.waitNative(h,h.boundary("source")); _ = try h.sql("native","STOP REPLICA")
                        try require(h.sql("target57","SELECT COUNT(*) FROM ddlcompat.t")=="0","target trigger executed")
                        try reporter.pass(test.id)
                    }
                for test in ModifyIndexCases.failures {
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
                    try writeJSON(["state":saved,"native":try h.status(),"source_before":before.json,"source_after":try h.boundary("source").json],to:f.output.appendingPathComponent(label+"-failure.json"))
                    // Fixture reset only: bypass this deliberately rejected range
                    // on the native reference before the next independent case.
                    _ = try h.sql("native","STOP REPLICA")
                    let end=try h.boundary("source")
                    _ = try h.sql("native","CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(end.file)',SOURCE_LOG_POS=\(end.position)")
                    try reporter.pass(label)
                }
                do {
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
                    let refusal=try runner.run(["docker","run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(evidenceVolume),dst=/evidence"] + CodeCoverage.environment(enabled: f.codeCoverage, label: label + "-skip-refusal") + ["--entrypoint","/usr/local/bin/mysql-replicator",image,"skip",id,"--config","/evidence/"+label+".yaml"],checked:false)
                    f.coverageInvocations.append(["label": label + "-skip-refusal", "exit_code": Int(refusal.status)])
                    try require(refusal.status != 0 && String(decoding:refusal.stderr,as:UTF8.self).contains("target write intents"),"uncertain DDL was eligible for skip")
                    let deadline=Date().addingTimeInterval(20)
                    while try h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='apply_fixture' OR INFO='DO SLEEP(8)'") != "0" {
                        try require(Date()<deadline,"timed-out server DDL did not finish after releasing fixture lock");Thread.sleep(forTimeInterval:0.1)
                    }
                    try require(h.sql("target57","SELECT COUNT(*) FROM demo.mi WHERE id=99")=="0","timeout applied following row")
                    try ModifyIndexCases.waitNative(h,h.boundary("source"));_ = try h.sql("native","STOP REPLICA")
                    try writeJSON(result,to:f.output.appendingPathComponent(label+"-failure.json"));try reporter.pass(label)
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
                    let failureJSON=try state(label,"SELECT diagnostic_json FROM target_failure")
                    guard let failure=try JSONSerialization.jsonObject(with:Data(failureJSON.utf8)) as? [String:Any],
                          let statement=failure["statement"] as? [String:Any],
                          let context=failure["ddlContext"] as? [String:Any] else {throw LabError("missing persisted DDL failure context")}
                    try require(failure["ddlSQL"] as? String == sql && failure["ddlGTID"] as? String != nil,"persisted failure lost SQL/GTID")
                    if test.id==DatabaseCreationCases.unsupportedDefault.id {
                        try require(context["serverCollationID"] as? Int == 255 && context["serverCollationName"] as? String == "utf8mb4_0900_ai_ci","persisted failure lost source server collation")
                        try require(context["database"] as? String == "created_bad_default" && statement["phase"] as? String == "notIssued","wrong database failure context/phase")
                        try require((failure["reason"] as? String ?? "").contains("ID 255 (utf8mb4_0900_ai_ci)"),"failure reason lacks collation identity")
                    } else if test.id==DatabaseCreationCases.unsupported.id {
                        try require((failure["reason"] as? String ?? "").contains("collation=utf8mb4_0900_ai_ci"),"failure reason lacks explicit collation")
                    }
                    let database=sql.split(separator:" ")[2]
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(database)'")=="0","rejected database was created")
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='after_"+label.replacingOccurrences(of:"-",with:"_")+"'")=="0","database failure did not block following DDL")
                    _ = try h.sql("native","STOP REPLICA")
                    try reporter.pass(label)
                }
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
                try writeJSON(nativeFailure,to:f.output.appendingPathComponent("native-like-missing-template-status.json"))
                _ = try h.sql("native","STOP REPLICA")
                try reporter.pass(DDLCoverageCases.missingTemplate.id)
                for (test,sql,reason) in DDLCoverageCases.rejections {
                    let label = test.id
                    let rejected=try start(test,configuration(label,at:try h.boundary("source"),count:2));try waitForReader(rejected)
                    _ = try h.sql("source",sql+"; CREATE TABLE poc.after_\(label)(id INT PRIMARY KEY)")
                    _ = try finish(rejected,label,success:false,reason:reason)
                    try require(state(label,"SELECT lifecycle||'|'||transactions_applied FROM state")=="BLOCKED|0","DDL rejection advanced progress")
                    try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME IN ('\(label)','after_\(label)')")=="0","rejected or following DDL was applied")
                    try reporter.pass(label)
                }
                // A valid source DDL outside the grammar stops before mutation.
                let unsupported=try start(DDLCoverageCases.unsupported,configuration("ddl-unsupported",at:try h.boundary("source"),count:1));try waitForReader(unsupported)
                _ = try h.sql("source","ALTER TABLE poc.items ADD unsupported JSON NULL")
                _ = try finish(unsupported,"ddl-unsupported",success:false,reason:"unsupported DDL column type")
                try require(h.sql("target57","SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='items' AND COLUMN_NAME='unsupported'") == "0","unsupported DDL mutated target")
                try require(state("ddl-unsupported","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","unsupported DDL advanced checkpoint")
                try reporter.pass("ddl-unsupported")
                // A target SQL error leaves a pending DDL intent, never applied.
                _ = try h.sql("target57","REVOKE CREATE ON poc.* FROM 'apply_fixture'@'%'")
                let denied=try start(DDLCoverageCases.denied,configuration("ddl-denied",at:try h.boundary("source"),count:1));try waitForReader(denied)
                _ = try h.sql("source","CREATE TABLE poc.denied(id INT PRIMARY KEY)")
                _ = try finish(denied,"ddl-denied",success:false,reason:"target SQL error")
                try require(state("ddl-denied","SELECT status FROM ddl_intents") == "PENDING","failed DDL intent lost")
                try require(state("ddl-denied","SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","failed DDL advanced checkpoint")
                try reporter.pass("ddl-denied")

            _ = try h.sql("target57","GRANT ALL PRIVILEGES ON *.* TO 'apply_fixture'@'%'")
            // Only this disposable native reference skips rejected ranges. The
            // target's blocked states and source events remain archived above.
            let end=try f.boundary()
            _ = try h.sql("native","STOP REPLICA; RESET BINARY LOGS AND GTIDS; SET GLOBAL gtid_purged='\(end.gtids)'; CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(end.file)',SOURCE_LOG_POS=\(end.position); START REPLICA")
            try SharedWorkflowCases.requirePassed(SharedWorkflowCases.failures,in:reporter.results)
        }
    }
}
