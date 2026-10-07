import Foundation

/// The same interruptions and checkpoint assertions run on both topologies.
/// Only service names, native control syntax and engine semantics vary.
enum LabLifecycle {
    static let cases: [QualificationCase] = [
        .init("source-reconnect","Disconnect, rotate, shut down and crash/restart the source without losing or replaying writes"),
        .init("source-reconnect-batch","Finish an active target group after source loss, then resume capture"),
        .init("source-reconnect-cancel","Stop cleanly during source reconnect backoff"),
        .init("source-reconnect-settings","Block incompatible source settings without advancing progress"),
        .init("target-reconnect","Reconnect an idle target socket and restart the target without replaying acknowledged writes"),
        .init("target-drain","Drain an active group into a clean, resumable checkpoint"),
        .init("target-drain-resume","Resume saved state while the target is initially unavailable"),
        .init("target-backoff-drain","Drain cleanly during target reconnect backoff"),
        .init("target-uncertain","Lost mutation reply blocks with durable evidence; InnoDB rolls back provisional writes"),
        .init("target-uncertain-resume","Ordinary resume refuses an unresolved target write"),
        .init("target-reconnect-settings","Block incompatible target settings without advancing progress")
    ]
    static func fields(_ profile: LabProfile) -> [[String:Any]] {
        cases.map { test in
            var row=test.fields
            row["profile"]=profile.rawValue; row["suite"]="lifecycle"; row["status"]="not_run"
            row["family"]=test.id.hasPrefix("source-") ? "source" : "target"
            row["expected"]=test.id.contains("uncertain") || test.id.hasSuffix("settings") ? "block without replay" : "resume or stop cleanly"
            row["target_engine"]=profile.targetEngine
            row["scope"]="GTID; ordered lifecycle experiments with bootstrapped tables"
            if test.id == "target-drain-resume" { row["dependencies"]=["target-drain"] }
            if test.id == "target-uncertain-resume" { row["dependencies"]=["target-uncertain"] }
            if test.id == "target-uncertain" {
                row["interruption"]=profile == .reverse ? "UPDATE second row blocked; first row provisional" : "INSERT blocked by MyISAM table lock"
            }
            return row
        }
    }

    final class Run {
        let f: LabFixture, reporter: QualificationReporter
        var configurations: [String:[String:Any]] = [:]
        var completed: Set<String> = []
        init(root: URL, profile: LabProfile, category: String, image: String) {
            f=LabFixture(root:root,category:category,image:image,profile:profile)
            reporter=QualificationReporter(output:f.output,log:f.stage)
        }
        func execute() throws {
            var report: [String:Any]=["profile":f.profile.rawValue,"topology":f.profile.topology,"result":"failed","positioning":"gtid"]
            var failure: Error?
            do {
                try f.prepare(build:false)
                // Match the server's persisted restart default throughout this
                // integer-only workload; optional FULL metadata is tested elsewhere.
                if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata=MINIMAL") }
                try f.recordRuntime()
                try f.awaitNative(); try native(start:false)
                // A stopped native dump connection can linger on the source.
                // Identify the external reader by its own fixture account.
                _ = try f.sql(.source,"SET sql_log_bin=0; CREATE USER 'lifecycle_capture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE,REPLICATION CLIENT ON *.* TO 'lifecycle_capture'@'%'")
                // Unlogged, equivalent bootstrap is outside each captured stream.
                for role in LabProfile.Role.allCases {
                    _ = try f.sql(role,"SET sql_log_bin=0; CREATE DATABASE lifecycle CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "+["source_rows","source_batch","target_rows","target_drain","target_uncertain"].map {
                        "CREATE TABLE lifecycle.\($0)(id INT PRIMARY KEY,v INT NOT NULL) ENGINE="+f.profile.engine(role)
                    }.joined(separator:"; "))
                }
                try sourceCases()
                try targetCases()
                try require(reporter.results.count == LabLifecycle.cases.count,"lifecycle runner omitted declared cases")
            } catch { failure=reporter.fail(error); report["error"]=String(describing:failure!) }
            var cleanup: [String]=[]
            for client in f.clients {
                do {
                    if try f.docker(["inspect",client,"--format","{{.State.Running}}"] ).text == "true" {
                        _ = try f.docker(["stop","--time","10",client])
                    }
                    let logs=try f.docker(["logs",client])
                    try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(client+".log"))
                } catch { cleanup.append(String(describing:error)) }
            }
            do {
                if try f.docker(["inspect",f.helper],checked:false).status == 0 {
                    _ = try f.docker(["cp",f.helper+":/evidence",f.output.appendingPathComponent("evidence").path])
                }
            } catch { cleanup.append("evidence: "+String(describing:error)) }
            do { try f.cleanup() } catch { cleanup.append(String(describing:error)) }
            report["cleanup"]=cleanup.isEmpty ? "passed" : cleanup.joined(separator:"; ")
            report["cases"]=reporter.results
            if !cleanup.isEmpty && failure == nil { failure=LabError(cleanup.joined(separator:"; ")) }
            report["result"]=failure == nil ? "passed" : "failed"
            try writeJSON(report,to:f.output.appendingPathComponent("result.json"))
            if let failure { throw failure }
            f.stage("PASS: source and target lifecycle (\(reporter.results.count) cases)")
        }
        func scenario(_ id: String, _ body: () throws -> Void) throws {
            try reporter.run(LabLifecycle.cases.first { $0.id == id }!,body)
        }
        func native(start: Bool) throws {
            _ = try f.sql(.native,(start ? "START " : "STOP ")+(f.profile == .reverse ? "SLAVE" : "REPLICA"))
        }
        func server(_ role: LabProfile.Role, start: Bool) throws {
            _ = try f.h.compose(start ? ["up","-d","--wait","--wait-timeout","120",f.profile.service(role)] : ["stop","-t","30",f.profile.service(role)],timeout:150)
        }
        func config(_ label: String, count: Int, smallInserts: Bool = false) throws -> [String:Any] {
            var value=f.config, source=value["source"] as! [String:Any]
            let boundary=try f.boundary()
            source["username"]="lifecycle_capture"
            source["start"]=["file":boundary.file,"position":boundary.position,"executedGTIDs":boundary.gtids]
            source["stopAfterTransactions"]=count; value["source"]=source
            value["stateDirectory"]="/evidence/state-"+label
            for key in ["sourceReconnect","targetReconnect"] { value[key]=["initialDelaySeconds":1,"maximumDelaySeconds":1,"maximumAttempts":60] }
            if smallInserts { value["batch"]=["maximumInsertRows":4] }
            return value
        }
        func start(_ label: String, _ config: [String:Any], initialize: Bool = true) throws -> String {
            configurations[label]=config
            let original=f.config; f.config=config
            defer { f.config=original }
            try f.installConfig(label)
            return try f.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
        }
        @discardableResult
        func finish(_ client: String, _ label: String, success: Bool = true, reason: String? = nil) throws -> [String:Any] {
            let exit=try f.runner.run(["docker","wait",client],timeout:120).text
            completed.insert(label)
            let logs=try f.docker(["logs",client])
            try logs.stdout.write(to:f.output.appendingPathComponent(label+".ndjson"))
            try logs.stderr.write(to:f.output.appendingPathComponent(label+".diagnostic.json"))
            try require(success ? exit == "0" : exit == "1","unexpected lifecycle exit \(exit): "+label)
            guard let line=logs.stderr.split(separator:10).last,
                  let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing final diagnostic: "+label) }
            if let reason { try require((result["reason"] as? String ?? "").contains(reason),"wrong lifecycle failure: \(result)") }
            return result
        }
        func waitProgress(_ client: String, _ predicate: ([String:Any])->Bool) throws {
            let deadline=Date().addingTimeInterval(60)
            while true {
                let logs=try f.docker(["logs",client])
                let records=logs.stdout.split(separator:10).compactMap { try? JSONSerialization.jsonObject(with:Data($0)) as? [String:Any] }
                if records.contains(where:predicate) { return }
                try require(try f.docker(["inspect",client,"--format","{{.State.Running}}"] ).text == "true","lifecycle client exited: "+String(decoding:logs.stderr,as:UTF8.self))
                try require(Date() < deadline,"lifecycle progress timeout")
                Thread.sleep(forTimeInterval:0.1)
            }
        }
        func waitReader(_ client: String) throws {
            let deadline=Date().addingTimeInterval(30)
            while try f.sql(.source,"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='lifecycle_capture' AND COMMAND LIKE 'Binlog Dump%'") != "1" {
                try require(try f.docker(["inspect",client,"--format","{{.State.Running}}"] ).text == "true" && Date() < deadline,"source reader did not start")
                Thread.sleep(forTimeInterval:0.1)
            }
        }
        func killConnection(_ role: LabProfile.Role) throws {
            let filter=role == .source ? "USER='lifecycle_capture' AND COMMAND LIKE 'Binlog Dump%'" : "USER='apply_fixture'"
            let id=try f.sql(role,"SELECT ID FROM information_schema.PROCESSLIST WHERE "+filter)
            try require(Int(id) != nil,"missing unique "+role.rawValue+" connection")
            _ = try f.sql(role,"KILL CONNECTION "+id)
        }
        func signal(_ client: String, _ signal: String) throws { _ = try f.docker(["kill","--signal",signal,client]) }
        func state(_ label: String, _ query: String) throws -> String {
            try require(completed.contains(label),"SQLite inspection requires an exited writer")
            let path=configurations[label]!["stateDirectory"] as! String
            let snapshot=f.output.appendingPathComponent("snapshots/"+label+"/"+runID())
            try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:true)
            _ = try f.docker(["cp",f.helper+":"+path,snapshot.path])
            return try f.runner.run(["sqlite3",snapshot.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent+"/state.sqlite").path,query]).text
        }
        func checkpoint(_ label: String, _ lifecycle: String, _ transactions: Int, _ rows: Int) throws {
            try require(try state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied FROM state") == "\(lifecycle)|\(transactions)|\(rows)","checkpoint differs: "+label)
            try require(try state(label,"SELECT COUNT(*) FROM groups WHERE status='APPLIED'") == String(transactions),"duplicate/missing journal groups: "+label)
            if lifecycle == "STOPPED" { try require(try state(label,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "0","pending writes after clean stop") }
        }
        func compare(_ query: String, _ expected: String) throws {
            try native(start:true); try f.awaitNative(); try native(start:false)
            for role in LabProfile.Role.allCases { try require(try f.sql(role,query) == expected,"lifecycle rows differ: "+role.rawValue) }
        }
        func caughtUp(_ summary: [String:Any], _ label: String) throws {
            let end=try f.boundary()
            try writeJSON(end.json,to:f.output.appendingPathComponent(label+"-source-end.json"))
            guard let gtids=summary["appliedGTIDSet"] as? String, let position=summary["appliedPosition"] as? [String:Any], let offset=position["position"] else { throw LabError("missing applied boundary") }
            try require(try f.sql(.source,"SELECT GTID_SUBSET('\(end.gtids)','\(gtids)')") == "1","applied GTIDs do not cover source")
            try require(position["file"] as? String == end.file && String(describing:offset) == String(end.position),"file/offset checkpoint differs")
        }
        func waitPartial(_ table: String) throws {
            let deadline=Date().addingTimeInterval(30)
            while true {
                let writes=Int(try f.sql(.target,"SELECT COUNT_WRITE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='lifecycle' AND OBJECT_NAME='\(table)'")) ?? 0
                if (1..<8000).contains(writes) { return }
                try require(writes < 8000 && Date() < deadline,"missed active group for "+table)
                Thread.sleep(forTimeInterval:0.02)
            }
        }
        func insertBatch(_ table: String) throws {
            let sql="INSERT INTO lifecycle.\(table) VALUES "+(1...8000).map { "(\($0),\($0))" }.joined(separator:",")
            _ = try f.sql(.source,sql)
        }
        func sourceCases() throws {
            try scenario("source-reconnect") {
                let label="source-reconnect", client=try start(label,config(label,count:5))
                try waitReader(client)
                _ = try f.sql(.source,"INSERT INTO lifecycle.source_rows VALUES(1,10)")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 1 }
                try killConnection(.source)
                try waitProgress(client) { $0["lifecycle"] as? String == "RECONNECTING" }
                try waitReader(client)
                _ = try f.sql(.source,"UPDATE lifecycle.source_rows SET v=v+1 WHERE id=1; FLUSH BINARY LOGS; INSERT INTO lifecycle.source_rows VALUES(2,20)")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 3 }
                try server(.source,start:false)
                try waitProgress(client) { ($0["sourceReconnectAttempts"] as? Int ?? 0) >= 2 }
                try server(.source,start:true); try waitReader(client)
                _ = try f.sql(.source,"UPDATE lifecycle.source_rows SET v=v+100 WHERE id=1")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 4 }
                let container=try f.h.compose(["ps","-q",f.profile.service(.source)]).text
                try signal(container,"KILL")
                try waitProgress(client) { ($0["sourceReconnectAttempts"] as? Int ?? 0) >= 3 }
                try server(.source,start:true); try waitReader(client)
                _ = try f.sql(.source,"INSERT INTO lifecycle.source_rows VALUES(3,30)")
                let result=try finish(client,label)
                try require((result["sourceReconnectAttempts"] as? Int ?? 0) >= 3,"source interruptions were not exercised")
                try caughtUp(result,label)
                try compare("SELECT id,v FROM lifecycle.source_rows ORDER BY id","1\t111\n2\t20\n3\t30")
                try checkpoint(label,"STOPPED",5,5)
            }
            try scenario("source-reconnect-batch") {
                let label="source-reconnect-batch", client=try start(label,config(label,count:2,smallInserts:true))
                try waitReader(client); try insertBatch("source_batch"); try waitPartial("source_batch")
                try killConnection(.source)
                try waitProgress(client) { $0["lifecycle"] as? String == "RECONNECTING" && $0["transactionsApplied"] as? Int == 1 }
                try waitReader(client)
                _ = try f.sql(.source,"UPDATE lifecycle.source_batch SET v=v+1 WHERE id=1")
                try caughtUp(finish(client,label),label)
                try compare("SELECT COUNT(*),SUM(v) FROM lifecycle.source_batch","8000\t32004001")
                try checkpoint(label,"STOPPED",2,8001)
            }
            try scenario("source-reconnect-cancel") {
                let label="source-reconnect-cancel", client=try start(label,config(label,count:1))
                try waitReader(client); try server(.source,start:false)
                try waitProgress(client) { $0["lifecycle"] as? String == "RECONNECTING" }
                try signal(client,"TERM"); try finish(client,label)
                try checkpoint(label,"STOPPED",0,0)
                try server(.source,start:true)
            }
            try scenario("source-reconnect-settings") {
                let label="source-reconnect-settings", client=try start(label,config(label,count:1))
                try waitReader(client)
                _ = try f.sql(.source,"SET GLOBAL binlog_row_image=MINIMAL")
                try killConnection(.source)
                let failed=try finish(client,label,success:false,reason:"source identity/settings differ")
                _ = try f.sql(.source,"SET GLOBAL binlog_row_image=FULL")
                let progress=failed["progress"] as? [String:Any]
                try require(progress?["sourceReconnectAttempts"] as? Int == 1,"incompatible source settings were retried")
                try checkpoint(label,"BLOCKED",0,0)
            }
        }
        func targetCases() throws {
            try scenario("target-reconnect") {
                let label="target-reconnect", client=try start(label,config(label,count:3))
                try waitReader(client)
                _ = try f.sql(.source,"INSERT INTO lifecycle.target_rows VALUES(1,10)")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 1 }
                try killConnection(.target)
                try waitProgress(client) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                try waitReader(client)
                _ = try f.sql(.source,"UPDATE lifecycle.target_rows SET v=11 WHERE id=1")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 2 }
                try server(.target,start:false)
                try waitProgress(client) { ($0["targetReconnectAttempts"] as? Int ?? 0) >= 2 }
                try server(.target,start:true); try waitReader(client)
                _ = try f.sql(.source,"INSERT INTO lifecycle.target_rows VALUES(2,20)")
                let result=try finish(client,label)
                try require((result["targetReconnectAttempts"] as? Int ?? 0) >= 2,"target interruptions were not exercised")
                try caughtUp(result,label)
                try compare("SELECT id,v FROM lifecycle.target_rows ORDER BY id","1\t11\n2\t20")
                try checkpoint(label,"STOPPED",3,3)
            }
            let drainConfig=try config("target-drain",count:2,smallInserts:true)
            try scenario("target-drain") {
                let label="target-drain", client=try start(label,drainConfig)
                try waitReader(client); try insertBatch("target_drain"); try waitPartial("target_drain")
                try signal(client,"USR1")
                let result=try finish(client,label)
                try require(result["drainRequested"] as? Bool == true,"drain was not reported")
                try caughtUp(result,label)
                try compare("SELECT COUNT(*),SUM(v) FROM lifecycle.target_drain","8000\t32004000")
                try checkpoint(label,"STOPPED",1,8000)
            }
            try scenario("target-drain-resume") {
                try server(.target,start:false)
                var value=drainConfig, source=value["source"] as! [String:Any]
                source["stopAfterTransactions"]=1; value["source"]=source
                let label="target-drain-resume", client=try start(label,value,initialize:false)
                try waitProgress(client) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                try server(.target,start:true); try waitReader(client)
                _ = try f.sql(.source,"UPDATE lifecycle.target_drain SET v=v+1 WHERE id=1")
                try caughtUp(finish(client,label),label)
                try compare("SELECT COUNT(*),SUM(v) FROM lifecycle.target_drain","8000\t32004001")
                try checkpoint(label,"STOPPED",2,8001)
            }
            try scenario("target-backoff-drain") {
                let label="target-backoff-drain", client=try start(label,config(label,count:1))
                try waitProgress(client) { $0["lifecycle"] as? String == "RUNNING" }
                try waitReader(client); try server(.target,start:false)
                try waitProgress(client) { $0["lifecycle"] as? String == "TARGET_RECONNECTING" }
                try signal(client,"USR1"); try finish(client,label)
                try checkpoint(label,"STOPPED",0,0)
                try server(.target,start:true)
            }
            let uncertainConfig=try config("target-uncertain",count:2)
            try scenario("target-uncertain") {
                let label="target-uncertain", client=try start(label,uncertainConfig)
                try waitReader(client)
                _ = try f.sql(.source,"INSERT INTO lifecycle.target_uncertain VALUES(0,0),(1,1)")
                try waitProgress(client) { $0["transactionsApplied"] as? Int == 1 }
                // InnoDB holds only the second row, allowing the first UPDATE to
                // succeed provisionally. MyISAM holds the whole table instead.
                let lock=f.profile == .reverse ? "START TRANSACTION; SELECT id FROM lifecycle.target_uncertain WHERE id=1 FOR UPDATE" : "LOCK TABLES lifecycle.target_uncertain WRITE"
                _ = try f.h.compose(["exec","-d","-e","MYSQL_PWD=fixture-root-only",f.profile.service(.target),"mysql","--no-defaults","-uroot","-e",lock+"; DO SLEEP(120)"])
                let deadline=Date().addingTimeInterval(30)
                while try f.sql(.target,"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(120)'") != "1" {
                    try require(Date() < deadline,"target blocker did not start"); Thread.sleep(forTimeInterval:0.05)
                }
                // MyISAM UPDATE checks its before-image first; the table lock
                // would block that read rather than an issued mutation.
                let mutation=f.profile == .reverse ? "UPDATE lifecycle.target_uncertain SET v=v+10 ORDER BY id" : "INSERT INTO lifecycle.target_uncertain VALUES(2,2),(3,3)"
                let operation=f.profile == .reverse ? "UPDATE" : "INSERT INTO"
                _ = try f.sql(.source,mutation)
                while try f.sql(.target,"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='apply_fixture' AND INFO LIKE '\(operation) %'") != "1" {
                    try require(Date() < deadline,"target mutation was not submitted"); Thread.sleep(forTimeInterval:0.05)
                }
                if f.profile == .reverse {
                    while try f.sql(.target,"SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; SELECT v FROM lifecycle.target_uncertain WHERE id=0") != "10" {
                        try require(Date() < deadline,"first InnoDB write was not observed before disconnect"); Thread.sleep(forTimeInterval:0.05)
                    }
                    try writeJSON(["id":0,"provisional_value":10,"committed_value_before":0],to:f.output.appendingPathComponent("target-provisional-write.json"))
                }
                try killConnection(.target)
                let failed=try finish(client,label,success:false,reason:"target connection")
                let blocker=try f.sql(.target,"SELECT ID FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(120)'")
                try require(Int(blocker) != nil,"target blocker exited before the interruption")
                _ = try f.sql(.target,"KILL CONNECTION "+blocker)
                try checkpoint(label,"BLOCKED",1,2)
                let diagnostic=try state(label,"SELECT diagnostic_json FROM target_failure")
                try require(diagnostic.contains("possiblyExecuted") && diagnostic.contains("target_uncertain"),"missing mutation evidence")
                if f.profile == .reverse {
                    let progress=failed["progress"] as? [String:Any], failure=progress?["targetFailure"] as? [String:Any]
                    try require(failure?["transactionOutcome"] as? String == "rollbackUnconfirmed","lost target connection must not claim a confirmed rollback")
                    try require(try state(label,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "2","failed transaction lost pending row evidence")
                }
                try require(try f.sql(.target,"SELECT id,v FROM lifecycle.target_uncertain ORDER BY id") == "0\t0\n1\t1","lost reply was replayed or left provisional InnoDB writes committed")
                try native(start:true); try f.awaitNative(); try native(start:false)
                let expected=f.profile == .reverse ? "0\t10\n1\t11" : "0\t0\n1\t1\n2\t2\n3\t3"
                for role: LabProfile.Role in [.source,.native] { try require(try f.sql(role,"SELECT id,v FROM lifecycle.target_uncertain ORDER BY id") == expected,"native failed the source-accepted transaction") }
            }
            try scenario("target-uncertain-resume") {
                let label="target-uncertain-resume", client=try start(label,uncertainConfig,initialize:false)
                try finish(client,label,success:false,reason:"cleanly STOPPED")
                try checkpoint(label,"BLOCKED",1,2)
                try require(try f.sql(.target,"SELECT id,v FROM lifecycle.target_uncertain ORDER BY id") == "0\t0\n1\t1","ordinary resume replayed unresolved writes")
            }
            try scenario("target-reconnect-settings") {
                let label="target-reconnect-settings", client=try start(label,config(label,count:1))
                try waitProgress(client) { $0["lifecycle"] as? String == "RUNNING" }; try waitReader(client)
                _ = try f.sql(.target,"SET GLOBAL binlog_row_image=MINIMAL")
                try killConnection(.target)
                try finish(client,label,success:false,reason:"target binary logging differs")
                _ = try f.sql(.target,"SET GLOBAL binlog_row_image=FULL")
                try checkpoint(label,"BLOCKED",0,0)
            }
        }
    }
}
