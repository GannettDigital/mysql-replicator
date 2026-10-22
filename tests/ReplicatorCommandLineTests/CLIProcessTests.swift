import Foundation
import XCTest

final class CLIProcessTests: XCTestCase {
    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, Data, Data) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryDirectory =
            ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"]
            ?? root.appendingPathComponent(".build/debug").path
        let process = Process()
        let out = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryDirectory).appendingPathComponent("mysql-replicator")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        process.standardOutput = out
        process.standardError = error
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    func testHelpAndVersionUseStdoutAndExitZero() throws {
        for args in [
            [], ["--help"], ["--version"], ["replay", "--help"], ["ctl", "--help"], ["ctl", "stop", "--help"],
            ["recovery", "--help"], ["recovery", "inspect", "--help"], ["recovery", "resolve", "--help"],
            ["help", "recovery", "resolve"],
            ["run", "--dry-run", "--help"], ["replay", "--dry-run", "--help"], ["validate", "--help"],
            ["config-help", "--command", "validate"],
            ["config-help", "--help"], ["config-help"], ["config-help", "--command", "ctl"],
            ["run", "--debug", "--help"], ["config-help", "--verbose", "--command", "ctl"],
        ] {
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 0, String(decoding: error, as: UTF8.self))
            XCTAssertFalse(out.isEmpty)
            XCTAssertTrue(error.isEmpty)
            if args == ["--version"] {
                XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("(codec ABI "))
            }
        }
    }

    func testValidationConfigurationFailureUsesChecklistAndExitOne() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("source: [secret-invalid-yaml\n".utf8).write(to: file)
        let (status, out, error) = try run(["validate", "--config", file.path, "--mode", "replay"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(error.isEmpty)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(report["ok"] as? Bool, false)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["name"] as? String, "configuration")
        XCTAssertEqual(checks.first?["status"] as? String, "failed")
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("secret-invalid-yaml"))
    }

    func testArgumentFailuresKeepJSONOnStderrAndExitOne() throws {
        for args in [
            ["run", "--dry-run", "--initialize", "--config", "/missing.yaml"],
            ["replay", "--dry-run", "--initialize", "--config", "/missing.yaml"],
            ["ctl"], ["recovery"], ["ctl", "wrong"],
            ["recovery", "resolve", "invalid"], ["skip"], ["inspect"],
            ["inspect", "--source-config"], ["not-a-command"], ["reply", "--config", "/missing.yaml"],
            ["--config", "/missing.yaml", "run"], ["run", "--config"],
            ["run", "--config", "/missing.yaml", "--config", "/missing.yaml"],
            ["run", "--config", "/missing.yaml", "--target.port"],
            ["run", "--config", "/missing.yaml", "--target.port", "1", "--target.port", "2"],
        ] {
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 1)
            XCTAssertTrue(out.isEmpty)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
            XCTAssertEqual(object["error"] as? String, "argument_error", args.joined(separator: " "))
            XCTAssertFalse((object["reason"] as? String ?? "").isEmpty)
            XCTAssertNil(object["offset"])
            XCTAssertNil(object["eventType"])
            if args.first == "reply" {
                XCTAssertTrue((object["reason"] as? String ?? "").contains("Did you mean 'replay'?"))
            }
        }
    }

    func testDefaultSelectionErrorsAndHelpDoesNotReadConfiguration() throws {
        let missing = "/tmp/missing-" + UUID().uuidString + ".yaml"
        let environment = ["MYSQL_REPLICATOR_CONFIG": missing]
        for args in [
            ["run"], ["replay"], ["fetch"], ["support-bundle"], ["ctl", "status"], ["recovery", "inspect"],
            ["skip", "uuid:1"],
        ] {
            let (status, out, error) = try run(args, environment: environment)
            XCTAssertEqual(status, 1)
            XCTAssertTrue(out.isEmpty)
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
            XCTAssertEqual(diagnostic["error"] as? String, "configuration_error")
            XCTAssertEqual(diagnostic["configPath"] as? String, missing)
        }
        for args in [["--help"], ["--version"], ["ctl", "status", "--help"], ["config-help", "--command", "ctl"]] {
            let (status, _, error) = try run(args, environment: environment)
            XCTAssertEqual(status, 0)
            XCTAssertTrue(error.isEmpty)
        }
    }

    func testConfigurationFailuresReportLocationsWithoutCreatingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("apply.yaml")
        let state = directory.appendingPathComponent("state")
        let secret = "do-not-copy-this-password"
        for (command, yaml, key) in [
            ("run", "stateDirectory: '\(state.path)'\nsource: [\(secret)\n", nil as String?),
            (
                "replay", "stateDirectory: '\(state.path)'\nsource:\n  password: '\(secret)'\n  password: duplicate\n",
                nil
            ),
            ("ctl", "stateDirectory: [\(secret)]\n", "stateDirectory"),
            ("ctl", "unrelated: '\(secret)'\n", "stateDirectory"),
        ] {
            try Data(yaml.utf8).write(to: file)
            let args =
                command == "ctl"
                ? [command, "status", "--config", file.path] : [command, "--config", file.path, "--initialize"]
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 1)
            XCTAssertTrue(out.isEmpty)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
            XCTAssertEqual(object["error"] as? String, "configuration_error")
            XCTAssertEqual(object["configPath"] as? String, file.path)
            if let key {
                XCTAssertEqual(object["keyPath"] as? String, key)
            } else {
                XCTAssertNotNil(object["line"])
                XCTAssertNotNil(object["column"])
            }
            XCTAssertFalse(String(decoding: error, as: UTF8.self).contains(secret))
            XCTAssertNil(object["offset"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        }
        let missing = directory.appendingPathComponent("missing.yaml")
        let (status, out, error) = try run(["skip", "uuid:1", "--config", missing.path])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(out.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
        XCTAssertEqual(object["error"] as? String, "configuration_error")
        XCTAssertEqual(object["configPath"] as? String, missing.path)
    }

    func testBinlogFailureKeepsDecoderCategoryAndOffset() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".binlog")
        try Data([0, 0, 0, 0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (status, out, error) = try run(["inspect", file.path])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(out.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
        XCTAssertEqual(object["error"] as? String, "binlog_decode_failed")
        XCTAssertEqual(object["offset"] as? String, "0")
        XCTAssertEqual(object["reason"] as? String, "invalid binlog magic")
    }

    func testCommandHelpIsShortAndConfigurationHelpIsScoped() throws {
        for args in [["--help"], ["ctl", "--help"], ["ctl", "status", "--help"], ["help", "recovery", "resolve"]] {
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 0)
            XCTAssertTrue(error.isEmpty)
            let text = String(decoding: out, as: UTF8.self)
            XCTAssertFalse(text.contains("--target.host"))
            XCTAssertFalse(text.contains("YAML example:"))
            XCTAssertLessThan(text.split(separator: "\n").count, 65)
        }
        let (status, out, error) = try run(["config-help", "--command", "replay", "--section", "target.transport"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(error.isEmpty)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("--target.transport ENUM"))
        XCTAssertTrue(text.contains("default: sql"))
        XCTAssertFalse(text.contains("--source.host"))
        for args in [
            ["config-help", "--command", "typo"], ["config-help", "--section", "typo"],
            ["config-help", "--command", "ctl", "--section", "target"],
            ["config-help", "--command", "run", "--command", "replay"],
        ] {
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 1)
            XCTAssertTrue(out.isEmpty)
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
            XCTAssertEqual(diagnostic["error"] as? String, "argument_error")
        }
    }

    func testReplayLogsPhasesWithoutSourceAccessOrLeakingCredentials() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // macOS's per-user temporary path can exceed the control socket limit.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("log-test-" + UUID().uuidString)
        let archive = directory.appendingPathComponent("binlogs")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),
            to: archive.appendingPathComponent("binlog.000003"))
        let config = directory.appendingPathComponent("apply.yaml")
        let secret = "never-log-this-target-password"
        let yaml = """
            version: 2
            stateDirectory: '\(directory.appendingPathComponent("state").path)'
            source:
              version: 2
              host: unused.invalid
              port: 3306
              username: unused
              requireTLS: false
              serverID: 9100
              sourceUUID: 8ba09bde-bc41-11f1-8272-ba06e9024a03
              mode: gtid
              start: {executedGTIDs: '8ba09bde-bc41-11f1-8272-ba06e9024a03:1-10'}
            target:
              unixSocket: /tmp/mysql-replicator-\(UUID().uuidString).sock
              username: unused
              password: '\(secret)'
              requireTLS: false
              nativeAutoStartDisabled: true
              preserveSourceGTIDs: false
            targetReconnect: {enabled: false}
            archive: {directory: '\(archive.path)'}
            """
        try Data(yaml.utf8).write(to: config)
        for mode in ["run", "replay"] {
            let (previewStatus, previewOut, previewError) = try run(
                [
                    mode, "--config", config.path, "--dry-run", "--source.stopAfterTransactions", "1",
                ] + (mode == "run" ? ["--source.password", secret] : []))
            XCTAssertEqual(previewStatus, 1)
            XCTAssertTrue(previewOut.isEmpty)
            let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: previewError) as? [String: Any])
            XCTAssertEqual(failure["error"] as? String, "dry_run_failed")
            XCTAssertEqual(failure["reason"] as? String, "target connection unavailable")
            XCTAssertFalse(String(decoding: previewError, as: UTF8.self).contains(secret))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state").path))
        }
        let (validationStatus, validationOut, validationError) = try run([
            "validate", "--config", config.path, "--mode", "replay",
        ])
        XCTAssertEqual(validationStatus, 1)
        XCTAssertTrue(validationError.isEmpty)
        let validation = try XCTUnwrap(JSONSerialization.jsonObject(with: validationOut) as? [String: Any])
        XCTAssertEqual(validation["kind"] as? String, "validation")
        XCTAssertEqual(validation["ok"] as? Bool, false)
        let checks = try XCTUnwrap(validation["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first { $0["name"] as? String == "target.connection" }?["status"] as? String, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state").path))
        XCTAssertFalse(String(decoding: validationOut, as: UTF8.self).contains(secret))
        let (status, out, error) = try run(["replay", "--config", config.path, "--initialize", "--verbose"])
        XCTAssertEqual(status, 1)  // Deliberately absent target socket.
        XCTAssertTrue(out.isEmpty)
        let records = try error.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let logs = records.filter { $0["kind"] as? String == "log" }
        let messages = logs.compactMap { $0["message"] as? String }
        XCTAssertFalse(messages.contains("Archive scan progress"), String(decoding: error, as: UTF8.self))
        XCTAssertTrue(messages.contains("Connect to target started"), messages.description)
        XCTAssertTrue(messages.contains("Connect to target finished"), messages.description)
        XCTAssertFalse(messages.contains("Connect to source started"))
        XCTAssertEqual(records.last?["error"] as? String, "apply_failed")
        XCTAssertFalse(String(decoding: error, as: UTF8.self).contains(secret))
        // A bad frame late in the archive must not hide an unavailable target.
        let file = archive.appendingPathComponent("binlog.000003")
        var corrupt = try Data(contentsOf: file)
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: file)
        let (corruptStatus, _, corruptError) = try run([
            "replay", "--config", config.path, "--initialize", "--verbose",
            "--stateDirectory", directory.appendingPathComponent("corrupt-state").path,
        ])
        XCTAssertEqual(corruptStatus, 1)
        let corruptRecords = try corruptError.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(corruptRecords.last?["reason"] as? String, "target connection unavailable")
        XCTAssertFalse(corruptRecords.contains { $0["kind"] as? String == "archive_progress" })
        XCTAssertFalse(corruptRecords.contains { $0["message"] as? String == "Archive scan progress" })
        let (skipStatus, _, skipError) = try run([
            "--verbose", "skip", "8ba09bde-bc41-11f1-8272-ba06e9024a03:11", "--config", config.path,
        ])
        XCTAssertEqual(skipStatus, 1)  // No captured pending transaction can be skipped.
        let last = try XCTUnwrap(skipError.split(separator: 10).last)
        let skipped = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last)) as? [String: Any])
        XCTAssertEqual(skipped["error"] as? String, "skip_failed")
    }
}
