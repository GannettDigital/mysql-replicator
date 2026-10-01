import Foundation

/// Retained, disposable demonstration of the same three-node qualification stack.
/// It provisions fixtures only; production dump/load and recovery stay out of scope.
public enum DemoSession {
    struct Manifest: Codable {
        let version: Int
        let identifier: String
        let image: String
        var ready: Bool
        func validate() throws {
            try require([1, 2].contains(version) && identifier.range(of: #"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z"#, options: .regularExpression) != nil,
                        "invalid demo session identity")
            try require(image.range(of: #"^sha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil, "invalid demo image identity")
        }
    }
    public static func run(root: URL, command: String, arguments: [String]) throws {
        if command == "demo-suite" {
            try require(arguments.isEmpty || arguments == ["--skip-build"], "demo-suite accepts only --skip-build")
            try qualify(root: root, build: arguments.isEmpty); return
        }
        let session = Session(root: root, category: "demo")
        switch command {
        case "demo-up":
            try require(arguments.isEmpty || arguments == ["--skip-build"], "demo-up accepts only --skip-build")
            try session.up(build: arguments.isEmpty)
        case "demo-start": try noArguments(arguments); try session.start()
        case "demo-status": try noArguments(arguments); try session.status()
        case "demo-compare":
            try require(arguments.isEmpty || arguments == ["--expect-blocked"], "demo-compare accepts only --expect-blocked")
            if arguments.isEmpty { try session.compare() } else { try session.verifyBlocked() }
        case "demo-sql":
            try require(arguments.count == 1, "demo-sql requires one SQL file path")
            try session.executeSQL(file: URL(fileURLWithPath: arguments[0], relativeTo: root))
        case "demo-fail": try noArguments(arguments); try session.fail()
        case "demo-down": try noArguments(arguments); try session.down()
        default: throw LabError("unknown demo command")
        }
    }
    private static func noArguments(_ args: [String]) throws { try require(args.isEmpty, "this demo command accepts no arguments") }

    final class Session {
        let root: URL, manifestURL: URL
        let category: String
        var manifest: Manifest?
        var harness: NativeHarness?
        init(root: URL, category: String) {
            self.root = root; self.category = category
            manifestURL = root.appendingPathComponent("artifacts/\(category)/current.json")
        }
        var h: NativeHarness { harness! }
        var volume: String { h.project + "-evidence" }
        var helper: String { h.project + "-demo-tools" }
        var applier: String { h.project + "-applier" }
        func log(_ text: String) { FileHandle.standardError.write(Data(("Demo: " + text + "\n").utf8)) }
        func docker(_ args: [String], checked: Bool = true, timeout: TimeInterval = 120) throws -> CommandResult {
            try h.runner.run(["docker"] + args, timeout: timeout, checked: checked)
        }
        func attach(_ m: Manifest) throws {
            try m.validate(); manifest = m
            var config = NativeCase(); config.transaction = false
            harness = NativeHarness(root: root, config: config, artifactCategory: category, identifier: m.identifier)
            h.composeOverlays = [root.appendingPathComponent("docker/dml/compose.yaml").path]
            h.composeEnvironment = ["REPLICATOR_DML_EVIDENCE_VOLUME": volume, "FIXTURE_DISABLED_ENGINES": "InnoDB"]
            if m.version == 2 {
                h.composeOverlays.append(root.appendingPathComponent("docker/demo/compose.yaml").path)
                h.composeEnvironment["REPLICATOR_DEMO_IMAGE"] = m.image
                h.composeEnvironment["REPLICATOR_DEMO_APPLIER"] = applier
            }
        }
        func load(ready: Bool = true) throws {
            try require(FileManager.default.fileExists(atPath: manifestURL.path), "no demo session; run make demo-up")
            try attach(JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))
            try require(!ready || manifest!.version == 2, "this demo uses the old container lifecycle; use demo-down then demo-up")
            try require(!ready || manifest!.ready, "demo setup is incomplete; inspect its artifacts and run make demo-down before retrying")
        }
        func save() throws {
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest!).write(to: manifestURL, options: .atomic)
        }
        func up(build: Bool) throws {
            try require(!FileManager.default.fileExists(atPath: manifestURL.path), "a demo session already exists; use demo-status or demo-down (up never resets data)")
            let id = runID(), runner = ProcessRunner(root: root), tag = "mysql-replicator-packaging:demo"
            if build {
                log("building the demo runtime with the existing Docker build caches")
                _ = try runner.run(["docker", "build", "--progress=plain", "--platform", "linux/amd64", "--target", "demo", "-f", "docker/packaging/Dockerfile", "-t", tag, "."], timeout: 3600, onOutput: { FileHandle.standardError.write($0) })
            }
            let image = try runner.run(["docker", "image", "inspect", tag, "--format", "{{.Id}}"] ).text
            try attach(Manifest(version: 2, identifier: id, image: image, ready: false)); try save()
            let tls = h.output.appendingPathComponent("tls")
            try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true)
            log("artifacts: \(h.output.path); setup failures retain this stack for inspection")
            func openssl(_ args: [String]) throws { _ = try runner.run(["openssl"] + args) }
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "7", "-subj", "/CN=Replicator Demo CA", "-keyout", tls.appendingPathComponent("ca-key.pem").path, "-out", tls.appendingPathComponent("ca.pem").path])
            try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=source", "-keyout", tls.appendingPathComponent("server-key.pem").path, "-out", tls.appendingPathComponent("server.csr").path])
            let ext = tls.appendingPathComponent("extensions.cnf")
            try "subjectAltName=DNS:source,DNS:target57\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to: ext, atomically: true, encoding: .utf8)
            try openssl(["x509", "-req", "-in", tls.appendingPathComponent("server.csr").path, "-CA", tls.appendingPathComponent("ca.pem").path, "-CAkey", tls.appendingPathComponent("ca-key.pem").path, "-CAcreateserial", "-days", "7", "-sha256", "-extfile", ext.path, "-out", tls.appendingPathComponent("server.pem").path])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tls.appendingPathComponent("server-key.pem").path)
            _ = try docker(["volume", "create", volume])
            _ = try docker(["run", "-d", "--name", helper, "--platform", "linux/amd64", "--network", "none", "--mount", "type=volume,src=\(volume),dst=/evidence", "--entrypoint", "/bin/sleep", image, "infinity"])
            _ = try docker(["cp", tls.path, helper + ":/evidence/tls"])
            try h.compose(["config"]).stdout.write(to: h.output.appendingPathComponent("compose.yaml"))
            log("starting MySQL servers and the idle applier container; mysql-replicator will remain unstarted")
            let startup = try h.compose(["up", "-d", "--build", "--wait", "--wait-timeout", "300"], timeout: 360, onOutput: { FileHandle.standardError.write($0) })
            try (startup.stdout + startup.stderr).write(to: h.output.appendingPathComponent("startup.log"))
            for service in h.services {
                let expected = service == "source" ? "ON\tON" : "OFF_PERMISSIVE\tWARN"
                try require(h.sql(service, "SELECT @@gtid_mode,@@enforce_gtid_consistency") == expected, "unexpected demo GTID settings")
                if service != "source" {
                    _ = try h.sql(service, "SET GLOBAL default_storage_engine=MyISAM; SET GLOBAL default_tmp_storage_engine=MyISAM")
                    try require(h.sql(service, "SELECT @@disabled_storage_engines") == "InnoDB", "demo needs explicit InnoDB rejection on both targets")
                }
            }
            _ = try h.sql("source", "CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'capture_fixture'@'%'; CREATE USER 'native_fixture'@'%' IDENTIFIED BY 'fixture-native-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'native_fixture'@'%'; SET GLOBAL binlog_row_metadata=FULL")
            _ = try h.sql("target57", "CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE,LOCK TABLES,TRIGGER,CREATE,ALTER,DROP ON demo.* TO 'apply_fixture'@'%'; GRANT REPLICATION CLIENT,SUPER ON *.* TO 'apply_fixture'@'%'; GRANT SELECT ON performance_schema.* TO 'apply_fixture'@'%'")
            let boundary = try h.boundary("source"), uuid = try h.sql("source", "SELECT @@server_uuid")
            try writeJSON(boundary.json, to: h.output.appendingPathComponent("baseline.json"))
            let config: [String: Any] = ["version": 2, "stateDirectory": "/evidence/state", "source": ["version": 2, "host": "source", "port": 3306, "username": "capture_fixture", "passwordEnvironment": "SOURCE_PASSWORD", "serverHostname": "source", "caFile": "/evidence/tls/ca.pem", "serverID": 9100, "sourceUUID": uuid, "mode": "gtid", "start": ["executedGTIDs": boundary.gtids], "idleTimeoutSeconds": 30], "target": ["host": "127.0.0.1", "port": 3306, "username": "apply_fixture", "passwordEnvironment": "TARGET_PASSWORD", "serverHostname": "target57", "caFile": "/evidence/tls/ca.pem", "nativeAutoStartDisabled": true]]
            try writeJSON(config, to: h.output.appendingPathComponent("apply.json"))
            _ = try docker(["cp", h.output.appendingPathComponent("apply.json").path, helper + ":/evidence/apply.json"])
            // Mount the same trusted CA used by the existing source/target overlay.
            let nativeID = try h.compose(["ps", "-q", "native"]).text
            _ = try docker(["cp", tls.appendingPathComponent("ca.pem").path, nativeID + ":/tmp/demo-ca.pem"])
            _ = try h.sql("native", "SET @@GLOBAL.gtid_purged='+\(boundary.gtids)'; CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='native_fixture',SOURCE_PASSWORD='fixture-native-only',SOURCE_SSL=1,SOURCE_SSL_CA='/tmp/demo-ca.pem',SOURCE_SSL_VERIFY_SERVER_CERT=1,SOURCE_AUTO_POSITION=1; START REPLICA")
            let nativeDeadline = Date().addingTimeInterval(25)
            while true {
                let native = try h.status()
                if native["Replica_IO_Running"] == "Yes" && native["Replica_SQL_Running"] == "Yes" && native["Last_IO_Errno"] == "0" && native["Last_SQL_Errno"] == "0" { break }
                try require(Date() < nativeDeadline, "native reference did not become ready; inspect native-status.txt")
                Thread.sleep(forTimeInterval: 0.2)
            }
            let targetID = try h.compose(["ps", "-q", "target57"]).text
            let targetCommand = try docker(["inspect", targetID, "--format", "{{json .Config.Cmd}}"] ).text
            try require(targetCommand.contains("--skip-slave-start"), "target must disable native auto-start")
            try require(applierStatus() == "running" && !replicatorRunning(), "demo-up must leave an idle, running applier container")
            try require(h.sql("source", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture'") == "0", "demo-up opened a Swift capture connection")
            try require(!hasState(), "demo-up unexpectedly created replication state")
            manifest!.ready = true; try save()
            try instructions().write(to: h.output.appendingPathComponent("COMMANDS.txt"), atomically: true, encoding: .utf8)
            print(instructions())
        }
        func instructions() -> String {
            """
            Ready: three MySQL servers and applier container running; mysql-replicator NOT_STARTED.
            Config: \(h.output.path)/apply.json (already installed as /evidence/apply.json)
            Source baseline: \(h.output.path)/baseline.json
            Login: docker exec -it \(applier) /bin/bash
            Inside applier: mysql-replicator run --config /evidence/apply.json --initialize
            Or start detached from host: make demo-start
            Detached logs: docker exec \(applier) tail -f /evidence/applier.ndjson /evidence/applier.stderr
            Successful SQL: make demo-sql FILE=examples/demo/01-success.sql
            Compare: make demo-compare
            Controlled failure: make demo-fail
            Inspect: make demo-status
            Read SQLite in Docker: docker exec \(helper) sqlite3 -readonly -header -column /evidence/state/state.sqlite 'SELECT * FROM state;'
            Interactive source SQL: docker exec -it -e MYSQL_PWD=fixture-root-only \(h.project)-source-1 mysql --no-defaults -uroot --default-character-set=utf8mb4
            Cleanup this disposable stack: make demo-down
            No automatic restart/resume. After stopping/failure, demo-down then demo-up creates a fresh demo.
            """
        }
        func applierStatus() throws -> String { try docker(["inspect", applier, "--format", "{{.State.Status}}"] ).text }
        func hasState() throws -> Bool { try docker(["exec", helper, "test", "-f", "/evidence/state/state.sqlite"], checked: false).status == 0 }
        func state(_ sql: String) throws -> String {
            try docker(["exec", helper, "/usr/local/bin/sqlite3", "-readonly", "-cmd", ".timeout 2000", "/evidence/state/state.sqlite", sql]).text
        }
        /// /proc identifies the binary independently of how it was started:
        /// direct foreground shell, detached exec, or the convenience command.
        func replicatorPIDs() throws -> [String] {
            if try applierStatus() != "running" { return [] }
            // Docker Desktop may expose qemu/rosetta as /proc/PID/exe.
            // Inspect only its executable argument, never grep a whole command
            // line (which would match our own inspection shell).
            let script = #"""
            for directory in /proc/[0-9]*; do
                executable=$(readlink "$directory/exe")
                case "$executable" in
                    /usr/local/bin/mysql-replicator) basename "$directory" ;;
                    */qemu-*|*/rosetta)
                        first= second=
                        { IFS= read -r -d '' first; IFS= read -r -d '' second; } < "$directory/cmdline" 2>/dev/null
                        if [ "$second" = /usr/local/bin/mysql-replicator ]; then basename "$directory"; fi
                        ;;
                esac
            done
            """#
            let pids = try docker(["exec", applier, "/bin/bash", "-c", script]).text.split(separator: "\n").map(String.init)
            try require(pids.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }, "invalid replicator process identity")
            return pids
        }
        func replicatorRunning() throws -> Bool { try !replicatorPIDs().isEmpty }
        func start() throws {
            try load()
            try require(applierStatus() == "running", "applier container is not running; inspect demo-status")
            try require(!replicatorRunning() && !hasState(), "mysql-replicator already started; restarting existing state is unsupported; use demo-down then demo-up")
            let command = "exec /usr/local/bin/mysql-replicator run --config /evidence/apply.json --initialize > /evidence/applier.ndjson 2> /evidence/applier.stderr"
            _ = try docker(["exec", "-d", applier, "/bin/sh", "-c", command])
            try waitForCapture()
            print("docker exec " + applier + " tail -f /evidence/applier.ndjson /evidence/applier.stderr")
        }
        func waitForCapture() throws {
            let deadline = Date().addingTimeInterval(25)
            var sawProcess = false
            while Date() < deadline {
                if try h.sql("source", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'") == "1" {
                    log("Swift replication is running; execute examples/demo/01-success.sql, then make demo-compare")
                    return
                }
                if try replicatorRunning() { sawProcess = true }
                else if try sawProcess || hasState() { throw LabError("mysql-replicator exited; run make demo-status for diagnostics") }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw LabError("capture did not become ready; run make demo-status")
        }
        func status() throws {
            try load(ready: false)
            print("Artifacts: " + h.output.path)
            // Include stopped containers and the applier in one compact table.
            let names = "^/" + h.project + "-(source-1|native-1|target57-1|applier)$"
            print(try docker(["ps", "--all", "--filter", "name=" + names,
                              "--format", "table {{.Names}}\t{{.Status}}"] ).text)
            let container = try docker(["inspect", applier, "--format", "{{json .State}}"], checked: false)
            print("Swift container: " + (container.status == 0 ? container.text : "not created"))
            if container.status == 0 {
                let pids = try replicatorPIDs()
                print("mysql-replicator process: " + (pids.isEmpty ? "NOT RUNNING" : "RUNNING (PID " + pids.joined(separator: ", ") + ")"))
            }
            if try hasState() {
                print("SQLite replication state:")
                print(try state("SELECT json_object('lifecycle',lifecycle,'source_uuid',source_uuid,'target_uuid',target_uuid,'baseline_gtids',baseline_gtids,'applied_file',applied_file,'applied_position',applied_position,'transactions_applied',transactions_applied,'rows_applied',rows_applied,'ddl_applied',ddl_applied,'active_gtid',active_gtid,'updated_at',updated_at,'diagnostic',diagnostic) FROM state;"))
                print("Recent DDL intents:")
                print(try state("SELECT json_object('gtid',gtid,'sql',target_sql,'status',status,'database',database_json) FROM ddl_intents ORDER BY rowid DESC LIMIT 5;"))
            } else { print("SQLite: NOT_STARTED (no state database)") }
            if let native = try? h.status() {
                print("Native 8.4: IO=\(native["Replica_IO_Running"] ?? "?") SQL=\(native["Replica_SQL_Running"] ?? "?") error=\(native["Last_SQL_Errno"] ?? "?") \(native["Last_SQL_Error"] ?? "")")
            }
            let logs = try docker(["exec", helper, "/bin/sh", "-c", "for file in /evidence/applier.ndjson /evidence/applier.stderr; do if [ -f \"$file\" ]; then tail -n 4 \"$file\"; fi; done"], checked: false)
            if !logs.stdout.isEmpty { print("Captured logs (demo-start):\n" + String(decoding: logs.stdout, as: UTF8.self)) }
        }
        func executeSQL(file: URL) throws {
            try load()
            let bytes = try Data(contentsOf: file)
            try require(bytes.count <= 1024 * 1024, "demo SQL file exceeds 1 MiB")
            guard let sql = String(data: bytes, encoding: .utf8) else { throw LabError("demo SQL must be UTF-8") }
            log("executing \(file.lastPathComponent) on source only")
            print(try h.sql("source", "SET NAMES utf8mb4; " + sql, headers: true))
        }
        func checkpoint() throws -> String {
            try state("SELECT COALESCE(applied_file,'')||'|'||COALESCE(applied_position,'')||'|'||transactions_applied||'|'||rows_applied||'|'||ddl_applied FROM state")
        }
        func observation(_ service: String) throws -> [String: String] {
            let schema = try h.sql(service, "SELECT t.TABLE_NAME,c.ORDINAL_POSITION,c.COLUMN_NAME,CONCAT(c.DATA_TYPE,IF(c.COLUMN_TYPE LIKE '%unsigned%',' unsigned','')),c.IS_NULLABLE,c.COLUMN_KEY,IFNULL(c.CHARACTER_MAXIMUM_LENGTH,0),IFNULL(c.COLLATION_NAME,'') FROM information_schema.TABLES t JOIN information_schema.COLUMNS c USING(TABLE_SCHEMA,TABLE_NAME) WHERE t.TABLE_SCHEMA='demo' ORDER BY t.TABLE_NAME,c.ORDINAL_POSITION", preserveWhitespace: true)
            let encoding = try h.sql(service, "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='demo'")
            let engine = try h.sql(service, "SELECT TABLE_NAME,ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' ORDER BY TABLE_NAME")
            let present = try h.sql(service, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items'") == "1"
            var rows = ""
            if present {
                let hasNote = try h.sql(service, "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items' AND COLUMN_NAME='note'") == "1"
                rows = try h.sql(service, "SELECT id,HEX(value),quantity" + (hasNote ? ",IFNULL(HEX(note),'NULL')" : "") + " FROM demo.items ORDER BY id", preserveWhitespace: true)
            }
            return ["schema": schema, "database": encoding, "engines": engine, "rows_hex": rows]
        }
        func compare() throws {
            try load()
            try require(replicatorRunning() && hasState(), "start mysql-replicator inside the applier container before comparing")
            let end = try h.boundary("source")
            let waited = try h.sql("native", "SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),20)")
            try require(waited != "NULL" && waited != "-1", "native replica did not reach the source boundary; inspect demo-status")
            let deadline = Date().addingTimeInterval(25)
            while true {
                let reached = try state("SELECT (applied_file='\(end.file)' AND applied_position='\(end.position)') OR (applied_sequence=0 AND baseline_gtids='\(end.gtids)') FROM state")
                if reached == "1" { break }
                try require(replicatorRunning() && Date() < deadline, "Swift did not reach the source boundary; inspect demo-status")
                Thread.sleep(forTimeInterval: 0.2)
            }
            var observations: [String: [String: String]] = [:]
            for service in h.services { observations[service] = try observation(service) }
            let source = observations["source"]!
            for service in ["native", "target57"] {
                let target = observations[service]!
                for field in ["database", "schema", "rows_hex"] { try require(target[field] == source[field], "\(service) differs in \(field)") }
                try require(target["engines"] == source["engines"]!.replacingOccurrences(of: "\tInnoDB", with: "\tMyISAM"), "\(service) engine mismatch")
            }
            let latest = try h.boundary("source")
            try require(latest.file == end.file && latest.position == end.position, "source changed during comparison; pause writes and compare again")
            let evidence: [String: Any] = ["result": "passed", "source_boundary": end.json, "checkpoint": try checkpoint(), "observations": observations]
            try writeJSON(evidence, to: h.output.appendingPathComponent("comparison.json"))
            print("PASS: source/native8.4/Swift5.7 schema and data agree; local engines are InnoDB/MyISAM/MyISAM.")
            print("Rows (id, HEX(value), quantity, HEX(note)): \n" + source["rows_hex"]!)
            print("Swift checkpoint: " + (try checkpoint()))
        }
        func fail() throws {
            try compare() // Save the exact completed boundary before inducing failure.
            try executeSQL(file: root.appendingPathComponent("examples/demo/02-failure.sql"))
            try verifyBlocked()
        }
        func verifyBlocked() throws {
            try load()
            let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: h.output.appendingPathComponent("comparison.json"))) as? [String: Any]
            let deadline = Date().addingTimeInterval(25)
            while try replicatorRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            try require(!replicatorRunning(), "mysql-replicator did not stop on the failure SQL")
            try require(applierStatus() == "running", "applier container should remain available after a replication failure")
            let diagnostic = try state("SELECT lifecycle||'|'||COALESCE(diagnostic,'') FROM state")
            try require(diagnostic.hasPrefix("BLOCKED|") && diagnostic.contains("explicit engine"), "unexpected Swift failure: " + diagnostic)
            try require(checkpoint() == previous?["checkpoint"] as? String, "Swift advanced its checkpoint past the last successful comparison")
            let end = try h.boundary("source")
            _ = try h.sql("native", "SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),5)")
            let native = try h.status()
            try require(native["Replica_SQL_Running"] == "No" && native["Last_SQL_Errno"] == "3161", "native did not reject explicit InnoDB with error 3161")
            var results: [String: [String: String]] = [:]
            for service in h.services {
                let table = try h.sql(service, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='explicit_innodb'")
                let marker = try h.sql(service, "SELECT COUNT(*) FROM demo.items WHERE id=999")
                try require(table == (service == "source" ? "1" : "0") && marker == (service == "source" ? "1" : "0"), "\(service) did not preserve the expected failure boundary")
                results[service] = ["failure_table": table, "following_marker": marker]
            }
            let previousObservations = previous?["observations"] as? [String: [String: String]]
            for service in ["native", "target57"] {
                try require(observation(service) == previousObservations?[service], "\(service) changed data/schema after the last successful comparison")
            }
            try writeJSON(["result": "passed", "swift_diagnostic": diagnostic, "native": native, "checkpoint": try checkpoint(), "observations": results], to: h.output.appendingPathComponent("failure.json"))
            print("PASS: native stopped with 3161; Swift is BLOCKED with an unchanged applied checkpoint. The failed table and following marker exist only on source.")
        }
        func down() throws {
            try load(ready: false)
            log("stopping only \(h.project); preserving evidence before deleting its disposable volumes")
            let exists = try docker(["inspect", applier], checked: false).status == 0
            if exists {
                // Docker exec children are not PID 1; signal the actual writer
                // before stopping the idle container and copying its SQLite files.
                let pids = try replicatorPIDs()
                if !pids.isEmpty {
                    _ = try docker(["exec", applier, "/bin/sh", "-c", #"kill -TERM "$@""#, "demo-stop"] + pids)
                    let deadline = Date().addingTimeInterval(15)
                    while try replicatorRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
                    try require(!replicatorRunning(), "writer did not exit; retaining the demo and its evidence")
                }
                _ = try docker(["stop", "--time", "10", applier])
                let logs = try docker(["logs", applier])
                try logs.stdout.write(to: h.output.appendingPathComponent("applier.ndjson"))
                try logs.stderr.write(to: h.output.appendingPathComponent("applier.stderr"))
            }
            if try docker(["inspect", helper], checked: false).status == 0 {
                // Writer has exited: only now copy SQLite/WAL and relay back to host.
                let captured = h.output.appendingPathComponent("captured")
                try FileManager.default.createDirectory(at: captured, withIntermediateDirectories: true)
                _ = try docker(["cp", helper + ":/evidence/.", captured.path])
            }
            _ = try docker(["rm", "-f", applier, helper], checked: false)
            _ = try h.compose(["down", "--volumes", "--remove-orphans"])
            let removed = try docker(["volume", "rm", volume], checked: false)
            try require(removed.status == 0 || (try docker(["volume", "inspect", volume], checked: false)).status != 0, "could not remove demo evidence volume")
            try FileManager.default.removeItem(at: manifestURL)
            log("cleaned up; retained artifacts: " + h.output.path)
        }
    }

    private static func qualify(root: URL, build: Bool) throws {
        let session = Session(root: root, category: "demo-suite")
        var failure: Error?
        var output: URL?
        var reporter: QualificationReporter?
        do {
            try session.up(build: build); output = session.h.output
            reporter = QualificationReporter(output: output!, log: session.log)
            try reporter!.run(QualificationCase("demo-prepared", "Compose starts a shell-accessible idle applier without starting mysql-replicator; repeated setup is refused")) {
                try require(session.applierStatus() == "running" && !session.replicatorRunning() && !session.hasState(), "stack was not independently prepared")
                try require(session.docker(["exec", session.applier, "/bin/bash", "-c", "test -r /evidence/apply.json && test -n \"$SOURCE_PASSWORD\" && test -n \"$TARGET_PASSWORD\" && mysql-replicator --version"]).text.contains("mysql-replicator"), "manual shell is not ready")
                var refused = false
                do { try session.up(build: false) } catch { refused = String(describing: error).contains("already exists") }
                try require(refused, "repeated up did not refuse")
            }
            try reporter!.run(QualificationCase("demo-start-idle", "Manually launch the CLI inside the running container; heartbeats keep the stream alive")) {
                // Same binary, arguments, shell, and inherited environment as the workbook.
                _ = try session.docker(["exec", "-d", session.applier, "/bin/bash", "-c", "exec mysql-replicator run --config /evidence/apply.json --initialize"])
                try session.waitForCapture()
                var refused = false
                do { try session.start() } catch { refused = String(describing: error).contains("already started") }
                try require(refused, "second start was not refused")
                session.log("checking 35 seconds of idle time with binlog heartbeats")
                Thread.sleep(forTimeInterval: 35)
                try require(session.replicatorRunning() && session.state("SELECT lifecycle FROM state") == "RUNNING", "idle demo applier stopped")
            }
            try reporter!.run(QualificationCase("demo-success", "Prepared SQL replicates database/table creation, DML and ADD COLUMN to both targets")) {
                try session.executeSQL(file: root.appendingPathComponent("examples/demo/01-success.sql")); try session.compare()
                try require(session.state("SELECT transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state") == "8|3|6", "unexpected demo counters")
                try require(session.h.sql("target57", "SELECT id,value,quantity,IFNULL(note,'NULL') FROM demo.items ORDER BY id") == "1\tupdated\t11\tafter DDL\n3\tthird\t30\tNULL", "unexpected demo data")
            }
            try reporter!.run(QualificationCase("demo-fail-stop", "Prepared failure stops both appliers before the following marker; SQLite checkpoint stays fixed")) {
                try session.fail(); try session.status()
            }
        } catch { failure = reporter?.fail(error) ?? error }
        if session.manifest != nil {
            do { try session.down() } catch { if failure == nil { failure = error } }
        }
        if let output { try writeJSON(["result": failure == nil ? "passed" : "failed", "diagnostic": failure.map(String.init(describing:)) ?? "", "cleanup": FileManager.default.fileExists(atPath: session.manifestURL.path) ? "incomplete" : "passed"], to: output.appendingPathComponent("result.json")) }
        if let failure { throw failure }
        let detached = Session(root: root, category: "demo-suite-detached")
        var detachedFailure: Error?
        do {
            try detached.up(build: false)
            let reporter = QualificationReporter(output: detached.h.output, log: detached.log)
            let test = QualificationCase("demo-detached-cleanup", "Convenience start launches a process in the idle container; cleanup stops an active writer before archiving SQLite")
            do {
                try reporter.run(test) {
                    try detached.start()
                    try require(detached.replicatorRunning(), "detached start did not launch the writer")
                    try detached.down()
                    let archived = detached.h.output.appendingPathComponent("captured/state/state.sqlite")
                    try require(FileManager.default.fileExists(atPath: archived.path), "cleanup did not archive SQLite")
                }
            } catch { throw reporter.fail(error) }
        } catch { detachedFailure = error }
        if FileManager.default.fileExists(atPath: detached.manifestURL.path), detached.manifest != nil {
            do { try detached.down() } catch { if detachedFailure == nil { detachedFailure = error } }
        }
        if let h = detached.harness {
            try writeJSON(["result": detachedFailure == nil ? "passed" : "failed", "diagnostic": detachedFailure.map(String.init(describing:)) ?? ""], to: h.output.appendingPathComponent("result.json"))
        }
        if let detachedFailure { throw detachedFailure }
        print("Demo suite PASS: setup/start separation, idle heartbeats, positive SQL, fail-stop and cleanup.")
    }
}
