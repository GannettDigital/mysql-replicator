import Foundation

/// Preserves the historical forward measurement contract, including target-local
/// TCP/Unix transports. Shared by streaming and capture; no interactive runner.
final class ForwardBenchmarkFixture {
    struct Manifest: Codable {
        let version: Int
        let identifier: String
        let image: String
        var ready: Bool
        var codeCoverage: Bool? = nil
        func validate() throws {
            try require([1, 2].contains(version) && identifier.range(of: #"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z"#, options: .regularExpression) != nil,
                        "invalid forward fixture identity")
            try require(image.range(of: #"^sha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil, "invalid forward fixture image identity")
        }
    }
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
    func log(_ text: String) { FileHandle.standardError.write(Data(("Forward benchmark: " + text + "\n").utf8)) }
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
            if m.codeCoverage == true {
                // Also capture manual shell commands and short-lived CLI checks.
                h.composeEnvironment["REPLICATOR_DEMO_PROFILE_FILE"] = "/evidence/code-coverage/manual-%p/%h-%m.profraw"
            }
        }
    }
    func load(ready: Bool = true) throws {
        try require(FileManager.default.fileExists(atPath: manifestURL.path), "no retained forward fixture session")
        try attach(JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))
        try require(!ready || manifest!.version == 2, "this fixture uses an obsolete container lifecycle")
        try require(!ready || manifest!.ready, "fixture setup is incomplete; inspect its artifacts and clean up before retrying")
    }
    func save() throws {
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest!).write(to: manifestURL, options: .atomic)
    }
    func up(build: Bool, targetTransport: String = "tcp-tls", batchTransactions: Int = 32, decoderProfiling: Bool = false, applierProfiling: Bool = false, insertRows: Int = 32, overlapPreparation: Bool = true, flushOnTableChange: Bool = false, explicitTableLocks: Bool = false, codeCoverage: Bool = false) throws {
        try require(["tcp-tls","unix-tls","unix"].contains(targetTransport),"invalid target transport")
        try require((1...256).contains(batchTransactions),"invalid DML batch size")
        try require(!FileManager.default.fileExists(atPath: manifestURL.path), "a fixture session already exists; clean it up before retrying (up never resets data)")
        let id = runID(), runner = ProcessRunner(root: root), tag = codeCoverage ? CodeCoverage.image : "mysql-replicator-packaging:demo"
        if build && codeCoverage {
            try CodeCoverage.build(runner)
        } else if build {
            log("building the demo runtime with the existing Docker build caches")
            _ = try runner.run(["docker", "build", "--progress=plain", "--platform", "linux/amd64", "--target", "demo", "-f", "docker/packaging/Dockerfile", "-t", tag, "."], timeout: 3600, onOutput: { FileHandle.standardError.write($0) })
        }
        let image = try runner.run(["docker", "image", "inspect", tag, "--format", "{{.Id}}"] ).text
        try CodeCoverage.validate(runner, image: image, enabled: codeCoverage)
        try attach(Manifest(version: 2, identifier: id, image: image, ready: false, codeCoverage: codeCoverage)); try save()
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
        // The interactive demo permits experiments in any database on its
        // disposable target, including CREATE DATABASE outside demo.*.
        _ = try h.sql("target57", "CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT ALL PRIVILEGES ON *.* TO 'apply_fixture'@'%'")
        let localTLS = targetTransport == "unix" ? "NONE" : "SSL"
        _ = try h.sql("target57", "CREATE USER 'apply_fixture'@'localhost' IDENTIFIED BY 'fixture-apply-only' REQUIRE \(localTLS); GRANT ALL PRIVILEGES ON *.* TO 'apply_fixture'@'localhost'")
        let boundary = try h.boundary("source"), uuid = try h.sql("source", "SELECT @@server_uuid")
        try writeJSON(boundary.json, to: h.output.appendingPathComponent("baseline.json"))
        var target: [String:Any] = ["username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","nativeAutoStartDisabled":true,"explicitTableLocks":explicitTableLocks]
        if targetTransport == "tcp-tls" { target["host"] = "127.0.0.1"; target["port"] = 3306 }
        else {
            try require(h.sql("target57","SELECT @@socket") == "/var/run/mysqld/mysqld.sock","unexpected fixture socket path")
            target["unixSocket"] = "/target-socket/mysqld.sock"
        }
        target["requireTLS"] = targetTransport != "unix"
        if targetTransport != "unix" { target["serverHostname"] = "target57"; target["caFile"] = "/evidence/tls/ca.pem" }
        let config: [String: Any] = ["version": 2, "applierProfiling": applierProfiling, "stateDirectory": "/evidence/state", "source": ["version": 2, "host": "source", "port": 3306, "username": "capture_fixture", "passwordEnvironment": "SOURCE_PASSWORD", "serverHostname": "source", "caFile": "/evidence/tls/ca.pem", "serverID": 9100, "sourceUUID": uuid, "mode": "gtid", "start": ["executedGTIDs": boundary.gtids], "idleTimeoutSeconds": 30, "decoderProfiling": decoderProfiling], "target": target]
        var batchedConfig=config
        batchedConfig["batch"] = ["maximumTransactions":batchTransactions,"maximumInsertRows":insertRows,"overlapPreparation":overlapPreparation,"flushOnTableChange":flushOnTableChange]
        try writeYAML(batchedConfig, to: h.output.appendingPathComponent("apply.yaml"))
        _ = try docker(["cp", h.output.appendingPathComponent("apply.yaml").path, helper + ":/evidence/apply.yaml"])
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
        try require(applierStatus() == "running" && !replicatorRunning(), "fixture setup must leave an idle, running applier container")
        try require(h.sql("source", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture'") == "0", "fixture setup opened a Swift capture connection")
        try require(!hasState(), "fixture setup unexpectedly created replication state")
        manifest!.ready = true; try save()
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
        try require(!replicatorRunning(), "mysql-replicator already started")
        let initialize = try !hasState()
        if !initialize { try require(state("SELECT lifecycle FROM state") == "STOPPED", "saved state is not STOPPED; unresolved failures require explicit recovery") }
        let command = "exec /usr/local/bin/mysql-replicator run --config /evidence/apply.yaml" + (initialize ? " --initialize" : "") + " > /evidence/applier.ndjson 2> /evidence/applier.stderr"
        _ = try docker(["exec", "-d"] + CodeCoverage.environment(enabled: manifest?.codeCoverage == true, label: runID()) + [applier, "/bin/sh", "-c", command])
        try waitForCapture()
        print("docker exec " + applier + " tail -f /evidence/applier.ndjson /evidence/applier.stderr")
    }
    func waitForCapture() throws {
        let deadline = Date().addingTimeInterval(25)
        var sawProcess = false
        while Date() < deadline {
            if try h.sql("source", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%'") == "1" {
                log("Swift capture connection is running")
                return
            }
            if try replicatorRunning() { sawProcess = true }
            else if sawProcess { throw LabError("mysql-replicator exited; inspect fixture diagnostics") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LabError("capture did not become ready; inspect fixture diagnostics")
    }
    func stopWriter(signal: String = "TERM") throws {
        let pids = try replicatorPIDs()
        if !pids.isEmpty {
            _ = try docker(["exec", applier, "/bin/sh", "-c", "kill -" + signal + #" "$@""#, "demo-stop"] + pids)
            let deadline = Date().addingTimeInterval(15)
            while try replicatorRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            try require(!replicatorRunning(), "writer did not exit; retaining the demo and its evidence")
        }
    }
    func down() throws {
        try load(ready: false)
        log("stopping only \(h.project); preserving evidence before deleting its disposable volumes")
        let exists = try docker(["inspect", applier], checked: false).status == 0
        if exists {
            // Docker exec children are not PID 1; signal the actual writer
            // before stopping the idle container and copying its SQLite files.
            try stopWriter()
            _ = try docker(["stop", "--time", "10", applier])
            let logs = try docker(["logs", applier])
            try logs.stdout.write(to: h.output.appendingPathComponent("applier.ndjson"))
            try logs.stderr.write(to: h.output.appendingPathComponent("applier.stderr"))
        }
        if try docker(["inspect", helper], checked: false).status == 0 {
            if manifest?.codeCoverage == true {
                try CodeCoverage.collect(h.runner, image: manifest!.image, volume: volume, label: h.project, allowEmpty: true)
            }
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
