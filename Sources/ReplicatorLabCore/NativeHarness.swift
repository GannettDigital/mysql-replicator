import Foundation

public struct NativeCase {
    public var autoPosition = true
    public var transaction = true
    public var nativeEngine = "MyISAM"
    public var initAutomatic = false
    public init() {}
    public var rejects: Bool { transaction && nativeEngine == "MyISAM" }
    public var name: String { "\(autoPosition ? "auto" : "position")-\(transaction ? "transaction" : "autocommit")-\(nativeEngine.lowercased())" }
}

public struct Boundary {
    public let file: String
    public let position: UInt64
    public let gtids: String
    public var json: [String: Any] { ["file": file, "position": position, "gtid_executed": gtids] }
}

public func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

public final class NativeHarness {
    let root: URL
    let runner: ProcessRunner
    let config: NativeCase
    let decoder: String
    public let output: URL
    let project: String
    var report: [String: Any]
    let services = ["source", "native", "target57"]

    var composeOverlays: [String] = []
    var composeEnvironment: [String: String] = [:]

    public init(root: URL, config: NativeCase, artifactCategory: String = "native-suite") {
        self.root = root; self.runner = ProcessRunner(root: root); self.config = config
        self.decoder = ProcessInfo.processInfo.environment["MYSQLBINLOG"] ?? "mysqlbinlog"
        let id = runID()
        output = root.appendingPathComponent("artifacts/\(artifactCategory)/\(id)-\(config.name)")
        project = "replicator-lab-" + id.lowercased()
        report = ["schema_version": 1, "case": config.name, "project": project,
                  "assertions": "failed", "expected_native_outcome": config.rejects ? "rejected_1837" : "applied",
                  "native_observed_outcome": "unknown", "swift_apply": "pending",
                  "native_engine": config.nativeEngine, "native_init_automatic": config.initAutomatic]
    }
    func compose(_ args: [String], timeout: TimeInterval = 120, checked: Bool = true) throws -> CommandResult {
        try runner.run(["docker", "compose", "-f", root.appendingPathComponent("compose.yaml").path, "-p", project] + composeOverlays.flatMap { ["-f", $0] } + args,
                       environment: ["FIXTURE_SOURCE_GTID_MODE": "ON", "FIXTURE_SOURCE_GTID_CONSISTENCY": "ON",
                                     "FIXTURE_NATIVE_GTID_MODE": "OFF_PERMISSIVE", "FIXTURE_NATIVE_GTID_CONSISTENCY": "WARN",
                                     "FIXTURE_TARGET57_GTID_MODE": "OFF_PERMISSIVE", "FIXTURE_TARGET57_GTID_CONSISTENCY": "WARN"].merging(composeEnvironment) { _, new in new },
                       timeout: timeout, checked: checked)
    }
    func sql(_ service: String, _ statement: String, headers: Bool = false) throws -> String {
        let prefix = service == "source" ? "" : "SET @@SESSION.GTID_NEXT = 'AUTOMATIC'; "
        return try compose(["exec", "-T", "-e", "MYSQL_PWD=fixture-root-only", service,
                            "mysql", "--no-defaults", "-uroot", "--batch", "--raw",
                            headers ? "--column-names" : "--skip-column-names", "-e", prefix + statement]).text
    }
    func boundary(_ service: String) throws -> Boundary {
        let fields = try sql(service, service == "target57" ? "SHOW MASTER STATUS" : "SHOW BINARY LOG STATUS").components(separatedBy: "\t")
        guard fields.count >= 2, let position = UInt64(fields[1]) else { throw LabError("invalid binlog boundary") }
        try require(fields[0].range(of: #"^binlog\.[0-9]+$"#, options: .regularExpression) != nil, "unexpected binlog filename")
        return Boundary(file: fields[0], position: position, gtids: try sql(service, "SELECT @@GLOBAL.gtid_executed"))
    }
    func rows(_ service: String) throws -> [[String]] {
        try sql(service, "SELECT id,value,quantity FROM poc.items ORDER BY id").components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
    }
    func engine(_ service: String) throws -> String {
        try sql(service, "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='items'")
    }
    func status() throws -> [String: String] {
        let text = try sql("native", "SHOW REPLICA STATUS\\G", headers: true)
        try text.write(to: output.appendingPathComponent("native-status.txt"), atomically: true, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    func capture(_ service: String, start: Boundary?, end: Boundary?) throws -> [RowOperation] {
        let directory = output.appendingPathComponent(service)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configSQL = "SELECT VERSION(),@@server_id,@@server_uuid,@@log_bin,@@binlog_format,@@binlog_row_image,@@binlog_checksum,@@gtid_mode,@@enforce_gtid_consistency,@@sync_binlog,@@innodb_flush_log_at_trx_commit"
        try sql(service, configSQL).write(to: directory.appendingPathComponent("configuration.tsv"), atomically: true, encoding: .utf8)
        try writeJSON(rows(service), to: directory.appendingPathComponent("rows.json"))
        _ = try sql(service, "FLUSH BINARY LOGS")
        let logs = try sql(service, "SHOW BINARY LOGS").components(separatedBy: "\n").dropLast()
        var checksums: [String: String] = [:]
        var operations: [RowOperation] = []
        for entry in logs {
            let name = entry.components(separatedBy: "\t")[0]
            try require(name.range(of: #"^binlog\.[0-9]+$"#, options: .regularExpression) != nil, "unsafe binlog filename")
            let raw = try compose(["exec", "-T", service, "cat", "/var/lib/mysql/" + name]).stdout
            try require(raw.count > 4 && raw.prefix(4) == Data([0xfe, 0x62, 0x69, 0x6e]), "invalid raw binlog")
            let file = directory.appendingPathComponent(name)
            try raw.write(to: file)
            let digest = try runner.run(["openssl", "dgst", "-sha256", file.path]).text.components(separatedBy: " ").last ?? ""
            try require(digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil, "invalid SHA-256 output")
            checksums[name] = digest
            if let start = start, let end = end, name == start.file {
                try require(start.file == end.file, "rotation within comparison window is not qualified yet")
                let decoded = try runner.run([decoder, "--no-defaults", "--verify-binlog-checksum",
                                              "--base64-output=DECODE-ROWS", "-vv", file.path])
                try decoded.stdout.write(to: directory.appendingPathComponent(name + ".txt"))
                try decoded.stderr.write(to: directory.appendingPathComponent("decoder.stderr"))
                operations = try BinlogReference.parse(String(decoding: decoded.stdout, as: UTF8.self), from: start.position, before: end.position)
            }
        }
        try writeJSON(checksums, to: directory.appendingPathComponent("sha256.json"))
        if start != nil && end != nil {
            try writeJSON(jsonObject(operations), to: directory.appendingPathComponent("operations.json"))
        }
        return operations
    }

    public func run() throws -> [String: Any] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Running \(config.name); evidence: \(output.path)")
        var failure: Error?
        var started = false
        var starts: [String: Boundary] = [:], ends: [String: Boundary] = [:]
        do {
            let version = try runner.run([decoder, "--no-defaults", "--version"]).text
            try require(version.contains("Ver 8.4."), "reference normalization requires a MySQL 8.4 mysqlbinlog; set MYSQLBINLOG")
            report["reference_decoder_version"] = version
            // Never load the developer's mysql option files: they can silently filter events.
            try compose(["config"]).stdout.write(to: output.appendingPathComponent("compose.yaml"))
            started = true
            let startup = try compose(["up", "-d", "--build", "--wait", "--wait-timeout", "300"], timeout: 600)
            try (startup.stdout + startup.stderr).write(to: output.appendingPathComponent("startup.log"))
            _ = try sql("source", "CREATE USER 'replicator_fixture'@'%' IDENTIFIED BY 'fixture-replication-only'; GRANT REPLICATION SLAVE ON *.* TO 'replicator_fixture'@'%'")
            for service in services {
                let expectedSettings = service == "source" ? "ON\tON" : "OFF_PERMISSIVE\tWARN"
                try require(sql(service, "SELECT @@gtid_mode,@@enforce_gtid_consistency") == expectedSettings, "effective GTID settings differ")
                let storage = service == "source" ? "InnoDB" : service == "native" ? config.nativeEngine : "MyISAM"
                _ = try sql(service, "CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(storage); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)")
                try require(engine(service) == storage, "wrong seeded engine")
                starts[service] = try boundary(service)
                try require(rows(service) == Fixture.seed, "seed mismatch")
            }
            let start = starts["source"]!
            report["start_boundaries"] = starts.mapValues(\.json)
            let positionClause: String
            if config.autoPosition {
                _ = try sql("native", "SET @@GLOBAL.gtid_purged='+" + start.gtids + "'")
                positionClause = "SOURCE_AUTO_POSITION=1"
            } else {
                positionClause = "SOURCE_AUTO_POSITION=0,SOURCE_LOG_FILE='\(start.file)',SOURCE_LOG_POS=\(start.position)"
            }
            if config.initAutomatic {
                _ = try sql("native", "SET @@GLOBAL.init_replica='SET @@SESSION.GTID_NEXT = ''AUTOMATIC'''")
                report["init_replica"] = try sql("native", "SELECT @@GLOBAL.init_replica")
            }
            _ = try sql("native", "CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='replicator_fixture',SOURCE_PASSWORD='fixture-replication-only',GET_SOURCE_PUBLIC_KEY=1,\(positionClause); START REPLICA")
            try Fixture.sql(transaction: config.transaction).write(to: output.appendingPathComponent("workload.sql"), atomically: true, encoding: .utf8)
            try writeJSON(jsonObject(Fixture.operations), to: output.appendingPathComponent("expected-operations.json"))
            try writeJSON(Fixture.final, to: output.appendingPathComponent("expected-rows.json"))
            _ = try sql("source", Fixture.sql(transaction: config.transaction))
            let end = try boundary("source")
            let delta = try sql("source", "SELECT GTID_SUBTRACT('\(end.gtids)','\(start.gtids)')")
            try require(!delta.isEmpty, "source emitted no workload GTIDs")
            report["workload_gtid_set"] = delta
            let waited = try sql("native", "SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),30)")
            var nativeStatus = try status()
            // SOURCE_POS_WAIT can return immediately when SQL fails before IO has
            // fetched the following transaction. Wait only for that receive barrier.
            let receiveDeadline = Date().addingTimeInterval(10)
            while nativeStatus["Read_Source_Log_Pos"] != String(end.position) && Date() < receiveDeadline {
                Thread.sleep(forTimeInterval: 0.2)
                nativeStatus = try status()
            }
            report["native_status"] = nativeStatus
            report["native_observed_outcome"] = nativeStatus["Last_SQL_Errno"] == "0" ? "applied" : "rejected_" + (nativeStatus["Last_SQL_Errno"] ?? "unknown")
            report["rows_at_barrier"] = try Dictionary(uniqueKeysWithValues: services.map { ($0, try rows($0)) })
            report["native_gtid_executed"] = try sql("native", "SELECT @@GLOBAL.gtid_executed")
            let covered = try sql("native", "SELECT GTID_SUBSET('\(delta)',@@GLOBAL.gtid_executed)") == "1"
            let observation = try NativeObservation(sourceRows: rows("source"), nativeRows: rows("native"), targetRows: rows("target57"),
                                                   status: nativeStatus, startPosition: String(start.position), endPosition: String(end.position),
                                                   reachedEnd: waited != "NULL" && waited != "-1", gtidCovered: covered)
            try observation.validate(expectedRejection: config.rejects, autoPosition: config.autoPosition)
            _ = try sql("native", "STOP REPLICA")
            try require(sql("target57", "SHOW SLAVE STATUS").isEmpty, "native replication exists on future Swift target")
            for service in services {
                ends[service] = try boundary(service)
                let expectedEngine = service == "source" ? "InnoDB" : service == "native" ? config.nativeEngine : "MyISAM"
                try require(engine(service) == expectedEngine, "engine changed")
            }
            report["end_boundaries"] = ends.mapValues(\.json)
            // Outside comparison windows; proves MyISAM writes survive ROLLBACK.
            for service in ["native", "target57"] {
                _ = try sql(service, "CREATE TABLE poc.rollback_probe(id INT PRIMARY KEY) ENGINE=MyISAM; BEGIN; INSERT INTO poc.rollback_probe VALUES(1); ROLLBACK")
                try require(sql(service, "SELECT COUNT(*) FROM poc.rollback_probe") == "1", "MyISAM rollback probe failed")
            }
            for service in services {
                let operations = try capture(service, start: starts[service], end: ends[service])
                let expected = service == "source" ? Fixture.operations : service == "target57" ? [] : config.rejects ? Array(Fixture.operations.prefix(1)) : Fixture.operations
                try Comparison.operations(operations, expected: expected)
            }
            report["logical_binlog_comparison"] = "passed_for_fixture_schema"
            report["myisam_rollback"] = "writes_survive"
        } catch {
            failure = error
            report["error"] = String(describing: error)
            if started {
                _ = try? sql("native", "STOP REPLICA")
                for service in services {
                    do { _ = try capture(service, start: nil, end: nil) }
                    catch { report["failure_capture_\(service)"] = String(describing: error) }
                }
            }
        }
        if started {
            do {
                let logs = try compose(["logs", "--no-color"])
                try (logs.stdout + logs.stderr).write(to: output.appendingPathComponent("containers.log"))
            } catch { report["logs_error"] = String(describing: error); if failure == nil { failure = error } }
            do { _ = try compose(["down", "--volumes", "--remove-orphans"]); report["cleanup"] = "passed" }
            catch { report["cleanup"] = String(describing: error); failure = error }
        } else { report["cleanup"] = "not_started" }
        report["assertions"] = failure == nil ? "passed" : "failed"
        try writeJSON(report, to: output.appendingPathComponent("result.json"))
        if let failure = failure { throw LabError("\(failure); evidence: \(output.path)") }
        print("PASS \(config.name): native \(report["native_observed_outcome"]!); Swift apply pending")
        return report
    }
}
