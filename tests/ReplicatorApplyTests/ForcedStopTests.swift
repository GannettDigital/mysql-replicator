import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ForcedStopTests: XCTestCase {
    private var fixture: ResumeTests {
        #if os(Linux)
        return ResumeTests(name: "fixtures", testClosure: { _ in })
        #else
        return ResumeTests()
        #endif
    }

    // Runs only in the child selected by the parent test. No production hooks,
    // test-only CLI modes, or unsafe post-fork Swift/Foundation work are needed.
    func testWriterProcessFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["REPLICATOR_FORCED_STOP_STATE"],
              let mode = environment["REPLICATOR_FORCED_STOP_MODE"] else { return }
        let f = fixture, groups = try f.helper.groups()
        let store = try StateStore(configuration: f.config(path))
        try store.bindTargetIdentity(f.target)
        try store.running()
        try f.apply(groups[0], to: store)
        if mode == "pending" {
            let group = groups[1]
            for event in group.events {
                try store.append(LiveRecord(kind: "event", file: group.start.file,
                                            observedPosition: String(event.nextPosition), event: event, rawBase64: nil))
            }
            try store.begin(group)
            try store.intent(0, DMLPlan.make(group, tables: f.helper.tables())[0])
        }
        try Data("ready".utf8).write(to: URL(fileURLWithPath: path + ".ready"), options: .atomic)
        // Keep the writer and its WAL alive until the parent sends SIGKILL.
        try withExtendedLifetime(store) {
            _ = try FileHandle.standardInput.read(upToCount: 1)
        }
        XCTFail("fixture must be killed before it can close state")
    }

    func testSIGKILLPreservesEvidenceAndRefusesAutomaticResume() throws {
        for mode in ["idle", "pending"] {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            addTeardownBlock { try FileManager.default.removeItem(at: parent) }
            let f = fixture, path = parent.appendingPathComponent("state"), configuration = try f.config(path.path)
            let log = path.deletingLastPathComponent().appendingPathComponent("child.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let input = Pipe(), child = Process()
            let selected = "ReplicatorApplyTests.ForcedStopTests/testWriterProcessFixture"
            #if os(macOS)
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", selected, Bundle(for: Self.self).bundlePath]
            #else
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [selected]
            #endif
            // XCTest can dump its environment on startup errors. Pass only
            // toolchain/runtime settings, never unrelated developer credentials.
            let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT",
                                        "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH",
                                        "LLVM_PROFILE_FILE", "ASAN_OPTIONS"]
            var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            environment["REPLICATOR_FORCED_STOP_STATE"] = path.path
            environment["REPLICATOR_FORCED_STOP_MODE"] = mode
            child.environment = environment
            child.standardInput = input
            child.standardOutput = output; child.standardError = output
            let exited = expectation(description: "killed writer exits: " + mode)
            child.terminationHandler = { _ in exited.fulfill() }
            try child.run()
            defer {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            }
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: path.path + ".ready") {
                guard child.isRunning && Date() < deadline else {
                    XCTFail("writer did not reach durable boundary: " + (try String(contentsOf: log, encoding: .utf8)))
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
            wait(for: [exited], timeout: 10)
            XCTAssertEqual(child.terminationReason, .uncaughtSignal)
            XCTAssertEqual(child.terminationStatus, SIGKILL)
            let database = path.appendingPathComponent("state.sqlite")
            let query = "SELECT lifecycle,transactions_applied,active_gtid,applied_position FROM state"
            let before = try f.helper.sqlite(database, query)
            XCTAssertEqual(before, [["RUNNING", "1", mode == "pending" ? f.helper.sid + ":12" : "NULL", "1885"]])
            let intents = try f.helper.sqlite(database, "SELECT gtid,status FROM row_intents ORDER BY gtid")
            XCTAssertEqual(intents, mode == "pending"
                           ? [[f.helper.sid + ":11", "DONE"], [f.helper.sid + ":12", "PENDING"]]
                           : [[f.helper.sid + ":11", "DONE"]])
            let relay = try Data(contentsOf: path.appendingPathComponent("relay.frames"))
            XCTAssertThrowsError(try StateStore(configuration: configuration, initialize: false)) {
                XCTAssertTrue(String(describing: $0).contains("cleanly STOPPED"))
            }
            XCTAssertEqual(try f.helper.sqlite(database, query), before)
            XCTAssertEqual(try f.helper.sqlite(database, "SELECT gtid,status FROM row_intents ORDER BY gtid"), intents)
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("relay.frames")), relay)
        }
    }
}
