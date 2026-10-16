import Foundation
import ReplicatorCapture
import ReplicatorConfiguration
import XCTest

@testable import ReplicatorApply

final class SupportBundleTests: XCTestCase {
    func testManualBundleUsesSavedReadFailureAheadOfCheckpoint() throws {
        #if os(Linux)
            let helper = ApplyTests(name: "fixtures", testClosure: { _ in })
        #else
            let helper = ApplyTests()
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: archive.appendingPathComponent("binlog.000003"))
        do {
            let store = try StateStore(configuration: helper.config(state.path))
            try store.recordSourceFailure("corrupt archive", at: .init(file: "binlog.000003", position: 1_500_000))
            try store.block("corrupt archive")
        }
        let c = try ConfigurationFile.decode(
            SupportBundleConfiguration.self,
            from: Data(
                """
                stateDirectory: \(state.path)
                archive:
                  directory: \(archive.path)
                supportBundle:
                  format: directory
                  maximumBytes: 1048576
                  binlogContextBytes: 4096
                """.utf8))
        let result = try SupportBundle.run(configuration: c, redactedConfiguration: Data("{}".utf8), version: "test")
        let index = try JSONDecoder().decode(
            BinlogExcerpt.Index.self,
            from: Data(contentsOf: URL(fileURLWithPath: result.output).appendingPathComponent("archive/binlog-0.json")))
        XCTAssertEqual(index.focusStart, 1_500_000)
        XCTAssertTrue(index.focusComplete)
        XCTAssertTrue(index.ranges.contains { $0.start < 1_500_000 && $0.end > 1_500_000 })
    }
    func testBundleRequiresStoppedWriterAndPreservesDiagnosticStateWithoutSecrets() throws {
        #if os(Linux)
            let helper = ApplyTests(name: "fixtures", testClosure: { _ in })
        #else
            let helper = ApplyTests()
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let output = root.appendingPathComponent("missing/parents/support.tar")
        let log = root.appendingPathComponent("large.log")
        try Data(repeating: 65, count: 1024 * 1024).write(to: log)
        let yaml = root.appendingPathComponent("apply.yaml")
        try """
        stateDirectory: \(state.path)
        source:
          password: highly-secret
        target:
          passwordEnvironment: SECRET_VAR
          privateKey: never-export
        supportBundle:
          output: \(output.path)
          maximumBytes: 1048576
          logs:
            - \(log.path)
        """.write(to: yaml, atomically: true, encoding: .utf8)
        let c = try ConfigurationFile.load(SupportBundleConfiguration.self, from: yaml)
        let diagnostic = try ConfigurationFile.diagnosticJSON(from: yaml)
        let text = String(decoding: diagnostic, as: UTF8.self)
        XCTAssertFalse(text.contains("highly-secret"))
        XCTAssertFalse(text.contains("SECRET_VAR"))
        XCTAssertFalse(text.contains("never-export"))
        do {
            let store = try StateStore(configuration: helper.config(state.path))
            try store.block("customer row value to preserve")
            XCTAssertThrowsError(
                try SupportBundle.run(configuration: c, redactedConfiguration: diagnostic, version: "test")
            ) {
                XCTAssertTrue(String(describing: $0).contains("active writer"))
            }
        }
        let db = state.appendingPathComponent("state.sqlite")
        let before = try ArchiveIO.hash(db)
        let result = try SupportBundle.run(configuration: c, redactedConfiguration: diagnostic, version: "test")
        XCTAssertTrue(result.containsCustomerData)
        XCTAssertGreaterThanOrEqual(result.files, 5)
        XCTAssertTrue(result.omitted.contains { $0.contains("logs/0.log: size limit") })
        XCTAssertEqual(try ArchiveIO.hash(db), before)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: Data("customer row value to preserve".utf8)))
        XCTAssertNil(bytes.range(of: Data("highly-secret".utf8)))
        XCTAssertThrowsError(
            try SupportBundle.run(configuration: c, redactedConfiguration: diagnostic, version: "test"))
        // Validate the archive using an independent reader, including SQLite.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-xf", output.path, "-C", root.path, "state.sqlite"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try helper.sqlite(root.appendingPathComponent("state.sqlite"), "SELECT lifecycle,diagnostic FROM state"),
            [["BLOCKED", "customer row value to preserve"]])
    }
    func testDefaultDestinationAndArchivePreambleSurvivePayloadLimit() throws {
        #if os(Linux)
            let helper = ApplyTests(name: "fixtures", testClosure: { _ in })
        #else
            let helper = ApplyTests()
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ReplicatorLabTests/Fixtures/source-positive.binlog")
        let file = archive.appendingPathComponent("binlog.000003")
        try FileManager.default.copyItem(at: fixture, to: file)
        // The bundle reads only the header. A large payload must not remove it.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2 * 1024 * 1024)
        try handle.close()
        do {
            let store = try StateStore(configuration: helper.config(state.path))
            try store.block("archive test")
        }
        let config = try ConfigurationFile.decode(
            SupportBundleConfiguration.self,
            from: Data(
                """
                stateDirectory: \(state.path)
                archive:
                  directory: \(archive.path)
                supportBundle:
                  format: directory
                  maximumBytes: 1048576
                """.utf8))
        let result = try SupportBundle.run(
            configuration: config, redactedConfiguration: Data("{}".utf8), version: "test")
        XCTAssertTrue(result.output.hasPrefix(root.appendingPathComponent("support-bundles").path + "/"))
        XCTAssertTrue(result.omitted.contains { $0.contains("archive/binlog.000003: partial file") })
        let inventory = URL(fileURLWithPath: result.output).appendingPathComponent("archive/inventory.json")
        let text = String(decoding: try Data(contentsOf: inventory), as: UTF8.self)
        XCTAssertTrue(text.contains("previousGTIDs"))
        XCTAssertTrue(text.contains(":1-5"))
        XCTAssertTrue(text.contains("2097152"))
        // A manual collection also accepts a configuration without supportBundle.
        let minimal = try ConfigurationFile.decode(
            SupportBundleConfiguration.self, from: Data("stateDirectory: \(state.path)".utf8))
        let defaultResult = try SupportBundle.run(
            configuration: minimal, redactedConfiguration: Data("{}".utf8), version: "test")
        XCTAssertTrue(defaultResult.output.hasSuffix(".tar"))
    }

}
