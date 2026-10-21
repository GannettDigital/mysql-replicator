import Foundation
import ReplicatorCapture
import XCTest

@testable import ReplicatorApply

func controlTestSummary(_ lifecycle: String) -> ApplySummary {
    ApplySummary(
        lifecycle: lifecycle, transactionsApplied: 2, rowsApplied: 2, ddlApplied: 0, appliedPosition: nil,
        appliedGTIDSet: "00000000-0000-0000-0000-000000000001:1-2", pendingGTID: nil, stateDirectory: "test",
        stageTimings: nil, pipeline: nil, sourceReconnectEnabled: false, sourceReconnectAttempts: 0,
        sourceReconnectReason: nil,
        targetReconnectEnabled: false, targetReconnectAttempts: 0, targetReconnectReason: nil, targetFailure: nil,
        drainRequested: lifecycle == "STOPPED")
}

final class RunControlTests: XCTestCase {
    func testControlCLIOutputsOneSortedJSONDocument() throws {
        let directory = URL(fileURLWithPath: "/tmp/repl-cli-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("apply.yaml")
        try Data("stateDirectory: \(directory.path)\n".utf8).write(to: config)
        // Use an unsorted socket response to test the CLI output boundary.
        let socket = try ControlSocket(directory: directory) { request in
            Data("{\"z\":{\"z\":2,\"a\":1},\"ok\":\(request.timeoutSeconds != 1),\"a\":\"/state/binlog\"}".utf8)
        }
        defer { socket.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryDirectory =
            ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"]
            ?? root.appendingPathComponent(".build/debug").path
        for (command, timeout) in [("status", 5), ("stop", 5), ("reload", 5), ("stop", 1)] {
            let process = Process()
            let out = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: binaryDirectory).appendingPathComponent("mysql-replicator")
            process.arguments = ["ctl", command, "--config", config.path, "--timeout", String(timeout)]
            process.standardOutput = out
            process.standardError = error
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, timeout == 1 ? 1 : 0)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stdout) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, timeout != 1)
            let text = String(decoding: stdout, as: UTF8.self)
            XCTAssertTrue(text.hasSuffix("\n"))
            XCTAssertTrue(text.contains("\n  \"a\""))
            XCTAssertTrue(text.contains("\n    \"a\""))
            XCTAssertTrue(text.contains("/state/binlog"))
            let names = text.components(separatedBy: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"")
            }
            .map { String($0.split(separator: "\"")[1]) }
            XCTAssertEqual(names, ["a", "ok", "z", "a", "z"])
            if timeout == 1 {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: stderr))
            } else {
                XCTAssertTrue(stderr.isEmpty)
            }
        }
    }

    func testLocalCommandsAcknowledgeCoordinatorAndCleanUpSocket() throws {
        let directory = URL(fileURLWithPath: "/tmp/repl-ctl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let drain = CaptureCancellation()
        let limits = try StopConditions(transactions: 10, gtids: nil)
        let control = RunControl(limits: limits, drain: drain) { try StopConditions(transactions: 20, gtids: nil) }
        try control.start(directory: directory)
        control.publish(controlTestSummary("RUNNING"))
        func reply(_ command: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(
                with: ControlClient.request(.init(command: command, timeoutSeconds: 5), stateDirectory: directory.path))
                as! [String: Any]
        }
        let status = try reply("status")
        XCTAssertEqual(status["configurationGeneration"] as? Int, 1)
        XCTAssertEqual((status["progress"] as? [String: Any])?["transactionsApplied"] as? Int, 2)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("control.sock").path)[
                .posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = expectation(description: "reload reply")
        DispatchQueue.global().async {
            do {
                let r = try reply("reload")
                XCTAssertEqual(r["ok"] as? Bool, true)
                XCTAssertEqual(r["configurationGeneration"] as? Int, 2)
            } catch { XCTFail(String(describing: error)) }
            reloaded.fulfill()
        }
        let until = Date().addingTimeInterval(3)
        while !control.reloadRequested && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(control.reloadRequested)
        control.acknowledge(.success(try control.candidate()))
        wait(for: [reloaded], timeout: 5)
        let stopped = expectation(description: "stop reply")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try reply("stop")["ok"] as? Bool, true) } catch { XCTFail(String(describing: error)) }
            stopped.fulfill()
        }
        let stopUntil = Date().addingTimeInterval(3)
        while !drain.isCancelled && Date() < stopUntil { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(drain.isCancelled)
        control.finish(controlTestSummary("STOPPED"))
        wait(for: [stopped], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        XCTAssertThrowsError(try reply("status"))
    }
    func testStatusRespondsWhileWorkerIsBlocked() throws {
        let directory = URL(fileURLWithPath: "/tmp/repl-live-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RunControl(limits: try .init(transactions: nil, gtids: nil), drain: .init()) {
            try .init(transactions: nil, gtids: nil)
        }
        control.activity.checkpoint(transactions: 2)
        control.publish(controlTestSummary("RUNNING"))
        try control.start(directory: directory)
        defer { control.finish(controlTestSummary("STOPPED")) }
        // Hold the worker in the same scoped status operation used around slow
        // reads. The socket must return before that operation is released.
        for (worker, phase) in [
            (RunActivity.Worker.target, "schemaDiscovery"),
            (.coordinator, "archiveValidation"), (.coordinator, "targetReconnectWait"),
            (.target, "targetExecution"),
        ] {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let completed = expectation(description: phase)
            DispatchQueue.global().async {
                control.activity.measure(worker, phase) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
                completed.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let data = try ControlClient.request(
                    .init(command: "status", timeoutSeconds: 1),
                    stateDirectory: directory.path)
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let progress = try XCTUnwrap(reply["progress"] as? [String: Any])
                let activity = try XCTUnwrap(progress["activity"] as? [String: Any])
                let phases = try XCTUnwrap(activity["phases"] as? [String: Any])
                XCTAssertEqual((phases[worker.rawValue] as? [String: Any])?["name"] as? String, phase)
                XCTAssertNotNil(activity["generatedAt"])
                XCTAssertEqual(progress["transactionsApplied"] as? Int, 2)
            } catch {
                release.signal()
                wait(for: [completed], timeout: 2)
                throw error
            }
            release.signal()
            wait(for: [completed], timeout: 2)
        }
    }
    func testControlDoesNotReplaceRegularFile() throws {
        let directory = URL(fileURLWithPath: "/tmp/repl-ctl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock")
        let contents = Data("keep me".utf8)
        try contents.write(to: path)
        let control = RunControl(limits: try .init(transactions: nil, gtids: nil), drain: .init()) {
            try .init(transactions: nil, gtids: nil)
        }
        XCTAssertThrowsError(try control.start(directory: directory))
        XCTAssertEqual(try Data(contentsOf: path), contents)
    }
}
