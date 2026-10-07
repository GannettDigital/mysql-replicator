import Foundation

/// Retained version of the same native-comparison fixture. All endpoints are
/// disposable and isolated; production bootstrap is deliberately not inferred.
public enum ReverseDemo {
    struct Manifest: Codable {
        let identifier: String
        var image: String
        var ready: Bool
        func validate() throws {
            try require(identifier.range(of:#"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z"#,options:.regularExpression) != nil,"invalid reverse demo identity")
            try require((!ready && image == "mysql-replicator-packaging:reverse") || image.range(of:#"^sha256:[0-9a-f]{64}\z"#,options:.regularExpression) != nil,"invalid reverse demo image")
        }
    }
    public static func run(root: URL, command: String, arguments: [String]) throws {
        let session=Session(root:root)
        switch command {
        case "reverse-demo-up":
            try require(arguments.isEmpty || arguments == ["--skip-build"],"reverse-demo-up accepts --skip-build")
            try session.up(build:arguments.isEmpty)
        case "reverse-demo-start": try noArguments(arguments); try session.start()
        case "reverse-demo-stop": try noArguments(arguments); try session.stop()
        case "reverse-demo-status": try noArguments(arguments); try session.status()
        case "reverse-demo-compare": try noArguments(arguments); try session.compare()
        case "reverse-demo-down": try noArguments(arguments); try session.down()
        case "reverse-demo-sql":
            try require(arguments.count == 1,"reverse-demo-sql requires a source SQL file")
            try session.executeSQL(URL(fileURLWithPath:arguments[0],relativeTo:root))
        case "reverse-demo-inspect":
            try noArguments(arguments); try session.load()
            print(try json(session.fixture!.recovery(["inspect"],label:"demo-inspection")))
        case "reverse-demo-resolve":
            try require(arguments.count == 5 && ["retry","skip","mark-applied"].contains(arguments[0]) && arguments[1] == "--gtids" && arguments[3] == "--reason","use reverse-demo-resolve ACTION --gtids GTID_SET --reason TEXT")
            try session.load()
            print(try json(session.fixture!.recovery(["resolve"]+arguments,label:"demo-resolution-"+runID())))
        case "reverse-demo-suite":
            try require(arguments.isEmpty || arguments == ["--skip-build"],"reverse-demo-suite accepts --skip-build")
            // The interactive session is never reused or overwritten by this test.
            let test=Session(root:root,category:"reverse-demo-suite")
            defer { try? test.down() }
            try test.up(build:arguments.isEmpty)
            try require(try test.applier.containerState() == "running" && test.applier.pids().isEmpty,"up must leave a running idle applier")
            let before=try test.statusText()
            try require(before.contains("NOT_STARTED") && !before.contains("No such container"),"fresh demo status is misleading")
            try test.start()
            try require(try test.statusText().contains("Replication: RUNNING"),"running status missing")
            try test.executeSQL(root.appendingPathComponent("examples/reverse-demo/01-success.sql"))
            try test.compare(); try test.stop()
            try require(try test.applier.containerState() == "running" && test.statusText().contains("STOPPED"),"drain must preserve shell and report STOPPED")
            // Reproduce the old up lifecycle: no applier container, saved state.
            _ = try test.fixture!.docker(["rm","-f",test.client])
            let missing=try test.statusText()
            try require(missing.contains("NOT_CREATED") && missing.contains("STOPPED") && !missing.contains("No such container"),"missing-container status lost saved progress")
            try test.up(build:false)
            try test.start()
            try test.executeSQL(root.appendingPathComponent("examples/reverse-demo/02-after-resume.sql"))
            try test.compare(); try test.stop()
            let f=test.fixture!
            _ = try f.h.sql("source","INSERT INTO reverse_poc.aux VALUES(99,99)")
            _ = try f.h.sql("target57","START TRANSACTION; UPDATE reverse_poc.items SET value='recovered' WHERE id=2; INSERT INTO reverse_poc.aux VALUES(99,99); COMMIT")
            try test.applier.start(initialize:false)
            let deadline=Date().addingTimeInterval(30)
            var failed: [String:Any] = [:]
            while Date() < deadline {
                if let report=try? f.recovery(["inspect"],label:"failure-state"), report["lifecycle"] as? String == "BLOCKED" { failed=report; break }
                Thread.sleep(forTimeInterval:0.2)
            }
            try require(!failed.isEmpty,"demo failure did not block")
            try require(try test.applier.containerState() == "running" && test.statusText().contains("Replication: BLOCKED"),"blocked applier lost shell or status")
            guard let pending=failed["pending"] as? [[String:Any]], let gtid=pending.first?["gtid"] as? String else { throw LabError("missing failure GTID") }
            _ = try f.h.sql("source","DELETE FROM reverse_poc.aux WHERE id=99")
            _ = try f.recovery(["resolve","retry","--gtids",gtid,"--reason","demo removed target-only conflict after rollback"],label:"demo-retry")
            try test.start(); try test.compare(); try test.stop()
            try writeJSON(["result":"passed","profile":"mysql57-to-mysql84-innodb"],to:test.fixture!.output.appendingPathComponent("demo-result.json"))
            print("PASS: reverse demo idle/status, SQL, native comparison, drain, missing-container repair, blocked status and recovery/resume")
        default: throw LabError("unknown reverse demo command")
        }
    }
    private static func noArguments(_ args: [String]) throws { try require(args.isEmpty,"command accepts no arguments") }
    private static func json(_ value: Any) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self) }

    final class Session {
        let root: URL, manifestURL: URL
        let category: String
        var fixture: ReverseFixture?
        init(root: URL, category: String = "reverse-demo") {
            self.root=root; self.category=category
            manifestURL=root.appendingPathComponent("artifacts/"+category+"/current.json")
        }
        var applier: ReverseDemoApplier { ReverseDemoApplier(fixture!) }
        var client: String { applier.name }
        func save(_ manifest: Manifest) throws {
            try FileManager.default.createDirectory(at:manifestURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(manifest).write(to:manifestURL,options:.atomic)
        }
        func load(ready: Bool = true) throws {
            try require(FileManager.default.fileExists(atPath:manifestURL.path),"no reverse demo; run make reverse-demo-up")
            let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifestURL)); try m.validate()
            try require(!ready || m.ready,"setup incomplete; inspect artifacts then run make reverse-demo-down")
            fixture=ReverseFixture(root:root,category:category,identifier:m.identifier,image:m.image)
        }
        func up(build: Bool) throws {
            if FileManager.default.fileExists(atPath:manifestURL.path) {
                try load(); try applier.ensureIdleContainer()
                print("Reusing the existing demo, pinned image, configuration and state.")
                try instructions().write(to:fixture!.output.appendingPathComponent("COMMANDS.txt"),atomically:true,encoding:.utf8)
                print(instructions()); return
            }
            var m=Manifest(identifier:runID(),image:"mysql-replicator-packaging:reverse",ready:false)
            try save(m)
            let f=ReverseFixture(root:root,category:category,identifier:m.identifier); fixture=f
            try f.prepare(build:build)
            var source=f.config["source"] as! [String:Any]
            source.removeValue(forKey:"stopAfterTransactions"); f.config["source"]=source
            try f.installConfig()
            try writeJSON(f.bootstrap,to:f.output.appendingPathComponent("baseline.json"))
            try applier.ensureIdleContainer()
            m.image=f.image; m.ready=true; try save(m)
            try instructions().write(to:f.output.appendingPathComponent("COMMANDS.txt"),atomically:true,encoding:.utf8)
            print(instructions())
        }
        func instructions() -> String {
            let f=fixture!
            return """
            Ready: 5.7 InnoDB source → replicator → 8.4 InnoDB, plus native 5.7 reference.
            The applier shell container is running; replication starts only when requested.
            Config: \(f.output.path)/apply.yaml; container path /evidence/apply.yaml
            Applier shell: docker exec -it \(client) /bin/bash
            Workbook: PLAN/REVERSE_DEMO_WORKBOOK.md
            Start: make reverse-demo-start
            Try: make reverse-demo-sql FILE=examples/reverse-demo/01-success.sql
            Compare: make reverse-demo-compare
            Source shell: docker exec -it -e MYSQL_PWD=fixture-root-only \(f.h.project)-target57-1 mysql --no-defaults -uroot
            Target shell: docker exec -it -e MYSQL_PWD=fixture-root-only \(f.h.project)-source-1 mysql --no-defaults -uroot
            Inspect: make reverse-demo-status
            Drain: make reverse-demo-stop
            Recovery: make reverse-demo-inspect (replication process must have exited)
            Cleanup: make reverse-demo-down
            DML only: use the preloaded reverse_poc tables. DDL and foreign keys remain unsupported.
            """
        }
        func running() throws -> Bool { try !applier.pids().isEmpty }
        func start() throws {
            try load(); let f=fixture!
            try require(try !running(),"reverse applier already running")
            let initialized=try applier.hasState()
            if initialized {
                let report=try f.recovery(["inspect"],label:"before-start")
                try require(report["lifecycle"] as? String == "STOPPED","resolve blocked/crashed state before restarting")
            }
            try applier.start(initialize:!initialized)
            let deadline=Date().addingTimeInterval(30)
            while true {
                let connections=try f.h.sql("target57","SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'")
                // Native uses the same fixture account, so expect two connections.
                if try connections == "2" && running() { break }
                try require(Date() < deadline,"reverse applier did not start; inspect reverse-demo-status")
                Thread.sleep(forTimeInterval:0.1)
            }
            print("Started: docker exec " + client + " tail -f /evidence/applier.ndjson /evidence/applier.stderr")
        }
        func stop() throws {
            try load(); try applier.drain(); try applier.archiveLogs()
            if try applier.hasState() {
                let report=try fixture!.recovery(["inspect"],label:"after-stop")
                try require(report["lifecycle"] as? String == "STOPPED","replication is blocked; inspect and resolve it before restarting")
            }
        }
        func status() throws { print(try statusText()) }
        func statusText() throws -> String {
            try load(ready:false); let f=fixture!
            var lines=["Artifacts: " + f.output.path,
                "Roles: source 5.7 = target57; native reference 5.7 = native; target 8.4 = source."]
            lines.append(try f.h.compose(["ps","--all"]).text)
            let container=try applier.containerState(), active=try running()
            lines.append("Applier container: " + container + " (" + client + ")")
            if active {
                lines.append("Replication: RUNNING")
                if let progress=try applier.latestProgress() {
                    lines.append("Applied GTIDs: " + (progress["appliedGTIDSet"] as? String ?? "unknown"))
                    lines.append("Transactions: \(progress["transactionsApplied"] ?? "?"); rows: \(progress["rowsApplied"] ?? "?")")
                }
                lines.append("Detached logs: docker exec " + client + " tail -f /evidence/applier.ndjson /evidence/applier.stderr")
            } else if try applier.hasState() {
                do {
                    let report=try f.recovery(["inspect"],label:"status-state")
                    lines.append("Replication: " + (report["lifecycle"] as? String ?? "UNKNOWN"))
                    lines.append("Applied GTIDs: " + (report["appliedGTIDSet"] as? String ?? "unknown"))
                    if let diagnostic=report["diagnostic"] as? String { lines.append("Diagnostic: " + diagnostic) }
                    lines.append("Start/resume: make reverse-demo-start (BLOCKED state needs explicit resolution)")
                } catch {
                    lines.append("Replication: NOT_RUNNING (saved state needs inspection)")
                    lines.append("Saved state inspection: " + String(describing:error))
                }
            } else {
                lines.append("Replication: NOT_STARTED (no state database)")
                lines.append("Next: make reverse-demo-start; or make reverse-demo-up to prepare the shell container")
            }
            let logs=try applier.logs(tail:true)
            if let line=logs.stderr.split(separator:10).last,
               let diagnostic=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any],
               let reason=diagnostic["reason"] as? String { lines.append("Last failure: " + reason) }
            let native=try f.h.sql("native","SHOW SLAVE STATUS\\G",headers:true)
            let fields=Dictionary(uniqueKeysWithValues:native.split(separator:"\n").compactMap { line -> (String,String)? in
                guard let colon=line.firstIndex(of:":") else { return nil }
                return (line[..<colon].trimmingCharacters(in:.whitespaces),line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces))
            })
            lines.append("Native 5.7: IO=\(fields["Slave_IO_Running"] ?? "?") SQL=\(fields["Slave_SQL_Running"] ?? "?") SQL error=\(fields["Last_SQL_Errno"] ?? "?") IO error=\(fields["Last_IO_Errno"] ?? "?")")
            for key in ["Last_SQL_Error","Last_IO_Error"] {
                if let value=fields[key], !value.isEmpty { lines.append(key + ": " + value) }
            }
            return lines.joined(separator:"\n")
        }
        func executeSQL(_ file: URL) throws {
            try load()
            let data=try Data(contentsOf:file)
            try require(data.count <= 1024*1024,"demo SQL exceeds 1 MiB")
            guard let sql=String(data:data,encoding:.utf8) else { throw LabError("SQL must be UTF-8") }
            print(try fixture!.h.sql("target57","SET NAMES utf8mb4; "+sql,headers:true))
        }
        func compare() throws {
            try load(); let f=fixture!
            // Drain makes the offline checkpoint/evidence read consistent. Restart
            // only if this command stopped an already running applier.
            let restart=try running(), end=try f.h.boundary("target57")
            if restart {
                let deadline=Date().addingTimeInterval(30)
                while true {
                    if let progress=try applier.latestProgress(),
                       let gtids=progress["appliedGTIDSet"] as? String,
                       try f.h.sql("target57","SELECT GTID_SUBSET('"+end.gtids+"','"+gtids+"')") == "1" { break }
                    try require(try running() && Date() < deadline,"replicator did not reach comparison boundary; inspect reverse-demo-status")
                    Thread.sleep(forTimeInterval:0.2)
                }
                try stop()
            }
            let report=try f.recovery(["inspect"],label:"comparison-state")
            try require(report["lifecycle"] as? String == "STOPPED","comparison requires a clean stop")
            guard let gtids=report["appliedGTIDSet"] as? String else { throw LabError("missing applied GTIDs") }
            try require(try f.h.sql("target57","SELECT GTID_SUBSET('"+end.gtids+"','"+gtids+"')") == "1","replicator has not caught up; restart and compare again")
            try f.compare()
            let after=try f.h.boundary("target57")
            try require(after.gtids == end.gtids,"pause source writes during comparison")
            try writeJSON(["result":"passed","boundary":end.json],to:f.output.appendingPathComponent("comparison.json"))
            print("PASS: source 5.7, native 5.7 and replicator 8.4 rows/schema/checkpoints agree")
            if restart { try start() }
        }
        func down() throws {
            try load(ready:false); let f=fixture!
            if try running() { try applier.drain() }
            try applier.archiveLogs()
            // Archive the stopped volume before deleting this disposable fixture.
            if try f.docker(["inspect",f.helper],checked:false).status == 0 {
                _ = try f.docker(["cp",f.helper+":/evidence",f.output.appendingPathComponent("evidence-"+runID()).path])
            }
            f.clients=[client]; try f.cleanup()
            try FileManager.default.removeItem(at:manifestURL)
            print("Reverse demo removed; evidence: " + f.output.path)
        }
    }
}
