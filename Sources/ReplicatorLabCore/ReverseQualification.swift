import Foundation

/// Independent initial profile qualification. The service names are inherited
/// from NativeHarness: target57 is our source; source is our 8.4 destination.
public enum ReverseQualification {
    public static func run(root: URL, build: Bool, events: Int = 100,onEvidence: ((URL)->Void)? = nil) throws {
        try require((0...100000).contains(events),"events must be 0...100000 (zero omits the benchmark)")
        let fixture=LabFixture(root:root)
        let h=fixture.h, runner=h.runner, output=h.output
        func stage(_ message: String) { fixture.stage(message) }
        func docker(_ args: [String], checked: Bool = true) throws -> CommandResult { try fixture.docker(args,checked:checked) }
        onEvidence?(output)
        var failure: Error?
        var report: [String:Any] = ["profile":"mysql57-to-mysql84-innodb","result":"failed"]
        do {
            try fixture.prepare(build:build)
            report.merge(fixture.versions) { _,new in new }
            report["image"]=fixture.image; report["baseline"]=fixture.bootstrap
            var config=fixture.config
            func run(_ label: String, initialize: Bool, success: Bool) throws -> [String:Any] {
                fixture.config=config; try fixture.installConfig(label)
                let client=try fixture.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml"] + (initialize ? ["--initialize"] : []))
                let exit = try runner.run(["docker","wait",client],timeout:300).text
                let logs = try docker(["logs",client])
                try logs.stdout.write(to:output.appendingPathComponent(label+".ndjson"))
                try logs.stderr.write(to:output.appendingPathComponent(label+".diagnostic.json"))
                try require(success ? exit == "0" : exit != "0","\(label) unexpected exit \(exit); inspect evidence")
                guard let line = logs.stderr.split(separator:10).last,
                      let summary = try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing reverse summary") }
                return summary
            }
            let positive = """
                START TRANSACTION;
                INSERT INTO reverse_poc.items VALUES
                  ('2026-10-06',2,'temporary',2.25,'ready','b',NULL),
                  ('2026-10-06',18446744073709551615,'héllo',3.50,'done','a,b',X'80FF');
                UPDATE reverse_poc.items SET value='intermediate' WHERE id=1;
                INSERT INTO reverse_poc.aux VALUES(1,10);
                UPDATE reverse_poc.items SET value='final',amount=7.75 WHERE id=1;
                DELETE FROM reverse_poc.items WHERE id=2;
                COMMIT;
                START TRANSACTION;
                UPDATE reverse_poc.items SET report_date='2026-10-07' WHERE id=18446744073709551615;
                INSERT INTO reverse_poc.aux VALUES(2,-20);
                COMMIT;
                """
            _ = try h.sql("target57",positive)
            report["positive"] = try run("positive",initialize:true,success:true)
            let comparison = LabFixture.comparison
            try fixture.awaitNative()
            for destination in ["source","native"] { try require(try h.sql("target57",comparison) == h.sql(destination,comparison),"reverse data mismatch: " + destination) }
            var source = config["source"] as! [String:Any]; source["stopAfterTransactions"] = 1; config["source"] = source
            _ = try h.sql("target57","START TRANSACTION; UPDATE reverse_poc.aux SET counter=11 WHERE id=1; UPDATE reverse_poc.items SET choice='ready' WHERE id=1; COMMIT")
            report["resume"] = try run("resume",initialize:false,success:true)
            try fixture.awaitNative()
            for destination in ["source","native"] { try require(try h.sql("target57",comparison) == h.sql(destination,comparison),"resumed data mismatch: " + destination) }
            if events > 0 {
            // Replay the same fully queued backlog sequentially, avoiding competing
            // appliers on one Docker host. Timings include CLI/startup/wait overhead.
            _ = try h.sql("native","STOP SLAVE")
            let workload = (0..<events).map { i in
                "START TRANSACTION; INSERT INTO reverse_poc.aux VALUES(\(1000+i),\(i)); UPDATE reverse_poc.items SET amount=\(i).00 WHERE id=1; COMMIT;"
            }.joined(separator:"\n")
            let workloadFile = output.appendingPathComponent("workload.sql")
            try workload.write(to:workloadFile,atomically:true,encoding:.utf8)
            let sourceID = try h.compose(["ps","-q","target57"]).text
            _ = try docker(["cp",workloadFile.path,sourceID+":/tmp/reverse-workload.sql"])
            stage("generating \(events) transactions, then measuring sequential backlog replay")
            _ = try h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only","target57","sh","-c","mysql --no-defaults -uroot < /tmp/reverse-workload.sql"],timeout:300)
            let nativeBefore=try fixture.counters("native"), targetBefore=try fixture.counters("source")
            let clock = ProcessInfo.processInfo.systemUptime
            _ = try h.sql("native","START SLAVE")
            try fixture.awaitNative()
            let nativeSeconds = ProcessInfo.processInfo.systemUptime-clock
            source["stopAfterTransactions"] = events; config["source"] = source
            let applyStart = ProcessInfo.processInfo.systemUptime
            let benchmark = try run("benchmark",initialize:false,success:true)
            let applySeconds = ProcessInfo.processInfo.systemUptime-applyStart
            report["benchmark"] = ["transactions":events,"native_seconds":nativeSeconds,"replicator_seconds":applySeconds,
                "native_transactions_per_second":Double(events)/nativeSeconds,"replicator_transactions_per_second":Double(events)/applySeconds,
                "scope":"Sequential backlog replay including CLI/startup/wait overhead; native 5.7 vs target 8.4, linux/amd64, durable InnoDB, one applier each; not isolated applier CPU time",
                "summary":benchmark]
            let nativeAfter=try fixture.counters("native"), targetAfter=try fixture.counters("source")
            report["benchmark_server_counter_deltas"] = ["native57":nativeAfter.reduce(into:[String:Int64]()) { $0[$1.key]=$1.value-(nativeBefore[$1.key] ?? 0) },
                "target84":targetAfter.reduce(into:[String:Int64]()) { $0[$1.key]=$1.value-(targetBefore[$1.key] ?? 0) }]
            report["server_counter_scope"] = "Global counters on isolated targets; includes control/status queries. Native row application does not issue SQL client statements."
            try fixture.compare()
            guard let applied=benchmark["appliedGTIDSet"] as? String else { throw LabError("missing benchmark GTID checkpoint") }
            let expected=try h.boundary("target57")
            try require(try h.sql("target57","SELECT GTID_SUBSET('"+expected.gtids+"','"+applied+"')") == "1","benchmark GTID checkpoint does not cover source")
            try require(benchmark["transactionsApplied"] as? Int == events+3,"benchmark checkpoint mismatch")
            stage("native: \(nativeSeconds)s; replicator: \(applySeconds)s")
            }
            source["stopAfterTransactions"] = 1; config["source"] = source
            // Diverge one key deliberately: source accepts both inserts, target
            // rejects the second. The first must roll back and stay unacknowledged.
            for destination in ["source","native"] { _ = try h.sql(destination,"INSERT INTO reverse_poc.aux VALUES(99,99)") }
            _ = try h.sql("target57","START TRANSACTION; UPDATE reverse_poc.items SET value='recovered' WHERE report_date='2026-10-06' AND id=1; INSERT INTO reverse_poc.aux VALUES(3,30); INSERT INTO reverse_poc.aux VALUES(99,99); COMMIT")
            let failed = try run("rollback",initialize:false,success:false)
            report["rollback"] = failed
            let progress = failed["progress"] as? [String:Any], diagnostic = progress?["targetFailure"] as? [String:Any]
            try require(diagnostic?["transactionOutcome"] as? String == "rolledBack","missing confirmed rollback diagnostic")
            try require(progress?["transactionsApplied"] as? Int == events+3,"failed transaction advanced checkpoint")
            try require(try h.sql("source","SELECT COUNT(*) FROM reverse_poc.aux WHERE id=3") == "0","partial transaction committed")
            _ = try docker(["cp",fixture.helper+":/evidence/state",output.path])
            let state = try runner.run(["sqlite3",output.appendingPathComponent("state/state.sqlite").path,"SELECT lifecycle,transactions_applied FROM state; SELECT DISTINCT status FROM row_intents WHERE gtid=(SELECT active_gtid FROM state)"]).text
            try require(state == "BLOCKED|\(events+3)\nPENDING","rollback journal lost pending evidence")
            let deadline = Date().addingTimeInterval(30)
            while true {
                let status = try h.sql("native","SHOW SLAVE STATUS\\G",headers:true)
                try status.write(to:output.appendingPathComponent("native-rollback-status.txt"),atomically:true,encoding:.utf8)
                if status.contains("Last_SQL_Errno: 1062") { break }
                try require(Date() < deadline,"native did not reject the duplicate key")
                Thread.sleep(forTimeInterval:0.1)
            }
            try require(try h.sql("native","SELECT COUNT(*) FROM reverse_poc.aux WHERE id=3") == "0","native partial transaction committed")
            report["state"] = state
            fixture.config=config; try fixture.installConfig()
            let inspected=try fixture.recovery(["inspect"],label:"recovery-inspection")
            let pending=inspected["pending"] as? [[String:Any]]
            try require(pending?.count == 1 && (pending?[0]["rows"] as? [Any])?.count == 3,"recovery inspection lost row evidence")
            let evidenceRows=pending?[0]["rows"] as? [[String:Any]]
            try require((evidenceRows?.first?["beforeKey"] as? [Any])?.count == 2,"recovery lost composite primary key")
            guard let gtid=pending?[0]["gtid"] as? String else { throw LabError("missing pending GTID") }
            // Reconcile the target-only conflicting row, then explicitly retry.
            for destination in ["source","native"] { _ = try h.sql(destination,"DELETE FROM reverse_poc.aux WHERE id=99") }
            report["recovery_resolution"]=try fixture.recovery(["resolve","retry","--gtids",gtid,"--reason","fixture removed target-only conflict; confirmed whole transaction rollback"],label:"recovery-resolution")
            _ = try h.sql("native","START SLAVE")
            report["recovery_resume"]=try run("recovered",initialize:false,success:true)
            try fixture.compare()
            let resolved=try fixture.recovery(["inspect"],label:"recovery-after-resume")
            try require((resolved["pending"] as? [Any])?.isEmpty == true && (resolved["audit"] as? [Any])?.count == 1,"recovery audit missing after resume")
            report["result"] = "passed"

        } catch {
            report["error"] = String(describing:error)
            failure=error
        }
        do { try fixture.cleanup(); report["cleanup"]="passed" }
        catch { report["cleanup"]=String(describing:error); if failure == nil { failure=error } }
        report["result"]=failure == nil ? "passed" : "failed"
        try writeJSON(report,to:output.appendingPathComponent("result.json"))
        if let failure { throw failure }
        stage("PASS: native comparison, multi-table transactions, composite keys, rollback and audited recovery/resume")
    }
}
