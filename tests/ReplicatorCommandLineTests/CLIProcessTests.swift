import Foundation
import XCTest

final class CLIProcessTests: XCTestCase {
    private func run(_ arguments: [String]) throws -> (Int32, Data, Data) {
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
            ["config-help", "--help"], ["config-help"], ["config-help", "--command", "ctl"],
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

    func testArgumentFailuresKeepJSONOnStderrAndExitOne() throws {
        for args in [
            ["run"], ["replay"], ["ctl"], ["recovery"], ["ctl", "wrong"],
            ["recovery", "resolve", "invalid"], ["skip"], ["fetch"], ["support-bundle"], ["inspect"],
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
}
