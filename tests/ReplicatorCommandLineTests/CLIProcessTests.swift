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
            ["help", "recovery", "resolve"],
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
        for (args, category) in [
            (["run"], "apply_failed"), (["replay"], "apply_failed"),
            (["ctl"], "apply_failed"), (["recovery"], "apply_failed"), (["ctl", "wrong"], "apply_failed"),
            (["recovery", "resolve", "invalid"], "apply_failed"),
            (["skip"], "skip_failed"), (["fetch"], "inspect_failed"),
            (["support-bundle"], "inspect_failed"), (["inspect"], "binlog_decode_failed"),
            (["inspect", "--source-config"], "inspect_failed"), (["not-a-command"], "binlog_decode_failed"),
        ] {
            let (status, out, error) = try run(args)
            XCTAssertEqual(status, 1)
            XCTAssertTrue(out.isEmpty)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: error) as? [String: Any])
            XCTAssertEqual(object["error"] as? String, category)
            XCTAssertFalse((object["reason"] as? String ?? "").isEmpty)
        }
    }
}
