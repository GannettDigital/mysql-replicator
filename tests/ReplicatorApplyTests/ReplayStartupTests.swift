import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture

extension ApplyTests {
    func testReplayCancelledBeforeReadinessDoesNotConnectOrScan() throws {
        let directory = URL(fileURLWithPath: "/tmp/replay-start-" + UUID().uuidString)
        let binlogs = directory.appendingPathComponent("binlogs")
        try FileManager.default.createDirectory(at: binlogs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),
            to: binlogs.appendingPathComponent("binlog.000003"))
        let configuration = try config(directory.appendingPathComponent("state").path)
        let archiveConfiguration = try JSONDecoder().decode(
            ArchiveConfiguration.self,
            from: JSONSerialization.data(withJSONObject: ["directory": binlogs.path]))
        var scanned = false
        let archive = try ArchiveReplay(
            configuration: archiveConfiguration, source: configuration.source, contract: .mysql84,
            progress: { _ in scanned = true })
        let cancellation = CaptureCancellation()
        cancellation.cancel()
        let result = try ApplyRun.run(
            configuration: configuration, sourcePassword: "", targetPassword: "unused",
            initialize: true, cancellation: cancellation, archive: archive)
        XCTAssertEqual(result.lifecycle, "STOPPED")
        XCTAssertEqual(result.transactionsApplied, 0)
        XCTAssertFalse(scanned)
        XCTAssertNil(archive.availableGTIDs)
        let store = try StateStore(configuration: configuration, initialize: false)
        XCTAssertEqual(store.gtids, configuration.source.start.executedGTIDs)
        XCTAssertNil(store.targetUUID)
    }
}

extension ApplyTests {
    func testReplayFileValidationSurvivesStateReopenWithoutAdvancingAppliedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binlogs = directory.appendingPathComponent("binlogs")
        try FileManager.default.createDirectory(at: binlogs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),
            to: binlogs.appendingPathComponent("binlog.000003"))
        let configuration = try config(directory.appendingPathComponent("state").path)
        let archiveConfiguration = try JSONDecoder().decode(
            ArchiveConfiguration.self, from: JSONSerialization.data(withJSONObject: ["directory": binlogs.path]))
        var progress: [ArchiveReplay.Progress] = []
        func archive() throws -> ArchiveReplay {
            try ArchiveReplay(
                configuration: archiveConfiguration, source: configuration.source, contract: .mysql84,
                progress: { progress.append($0) })
        }
        func scanAndClose() throws {
            let state = try StateStore(configuration: configuration)
            try archive().validate(baseline: state.gtids, persistence: state.archiveValidationPersistence())
            XCTAssertEqual(state.gtids, configuration.source.start.executedGTIDs)
            XCTAssertEqual(state.transactions, 0)
            XCTAssertNil(state.applied)
            XCTAssertNil(state.targetUUID)
            try state.archiveValidationStopped()
        }
        try scanAndClose()
        progress = []
        let state = try StateStore(configuration: configuration, initialize: false)
        try archive().validate(baseline: state.gtids, persistence: state.archiveValidationPersistence())
        XCTAssertTrue(progress.contains { $0.phase == "validation_file_reused" })
        XCTAssertEqual(progress.last?.bytesRead, 0)
        XCTAssertEqual(progress.last?.preambleBytesRead, 0)
        XCTAssertEqual(state.gtids, configuration.source.start.executedGTIDs)
        XCTAssertEqual(state.transactions, 0)
        XCTAssertNil(state.applied)
        XCTAssertNil(state.targetUUID)
        let database = directory.appendingPathComponent("state/state.sqlite")
        let rows = try sqlite(database, "SELECT payload FROM archive_validation")
        XCTAssertEqual(rows.count, 1)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[0][0].utf8)) as? [String: Any])
        XCTAssertEqual(metadata["firstGTID"] as? String, sid + ":6")
        XCTAssertEqual(metadata["firstTransactionOffset"] as? Int, 198)
        XCTAssertEqual(metadata["preambleEndOffset"] as? Int, 198)
        XCTAssertEqual((metadata["identity"] as? [String: Any])?["size"] as? Int, 2885)
        XCTAssertEqual(try sqlite(database, "SELECT COUNT(*) FROM groups"), [["0"]])
        try state.archiveValidationPersistence().prepare([])
        XCTAssertEqual(try sqlite(database, "SELECT COUNT(*) FROM archive_validation"), [["0"]])
    }
}
