import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ResumeTests {
    /// Preserve the fixture's real offsets in file 3. Empty files on either side
    /// make it a middle-file replay case with actual preambles and rotation.
    func recoveryArchive(_ c: ApplyConfiguration) throws -> (URL, ArchiveConfiguration) {
        let dir = URL(fileURLWithPath: c.stateDirectory).deletingLastPathComponent().appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = try Data(
            contentsOf: helper.root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
        let formatLength = Int(ArchiveIO.read(original, at: 13, as: UInt32.self))
        let format = Data(original[4..<4 + formatLength])
        func emptyFile(previous: String, next: String?) throws -> Data {
            var bytes = Data([0xfe, 0x62, 0x69, 0x6e])
            bytes.append(format)
            func append(_ input: Data) {
                var frame = input
                frame[17] &= ~0x20
                var position = UInt32(bytes.count + frame.count).littleEndian
                withUnsafeBytes(of: &position) { frame.replaceSubrange(13..<17, with: $0) }
                var crc = ArchiveIO.crc32(Data(frame.dropLast(4))).littleEndian
                withUnsafeBytes(of: &crc) { frame.replaceSubrange(frame.count - 4..<frame.count, with: $0) }
                bytes.append(frame)
            }
            append(
                ArchiveIO.pseudo(type: 35, position: 0, body: Data(try GTIDSet(previous).encoded().readableBytesView)))
            if let next { append(ArchiveIO.announce(next)) }
            return bytes
        }
        try emptyFile(previous: helper.sid + ":1-5", next: "binlog.000003").write(
            to: dir.appendingPathComponent("binlog.000002"))
        try original.write(to: dir.appendingPathComponent("binlog.000003"))
        try emptyFile(previous: helper.sid + ":1-14", next: nil).write(to: dir.appendingPathComponent("binlog.000004"))
        let archive = try JSONDecoder().decode(
            ArchiveConfiguration.self, from: JSONSerialization.data(withJSONObject: ["directory": dir.path]))
        return (dir, archive)
    }

    func testMiddleFileDecodeFailureCanBeInspectedBundledAndRetriedBeforeTargetBinding() throws {
        let path = try directory()
        let c = try helper.config(path.path)
        let (dir, archiveConfig) = try recoveryArchive(c)
        let file = dir.appendingPathComponent("binlog.000003")
        let original = try Data(contentsOf: file)
        var corrupt = original
        // A GTID sequence of zero is invalid. The frame and CRC remain intact,
        // so the semantic decoder must report the original physical offset.
        corrupt.replaceSubrange(1885 + 36..<1885 + 44, with: Data(repeating: 0, count: 8))
        var crc = ArchiveIO.crc32(Data(corrupt[1885..<1960])).littleEndian
        withUnsafeBytes(of: &crc) { corrupt.replaceSubrange(1960..<1964, with: $0) }
        try corrupt.write(to: file)
        let archive = try ArchiveReplay(configuration: archiveConfig, source: c.source, contract: .mysql84)
        var failure: ArchiveReadError?
        XCTAssertThrowsError(try archive.validate(baseline: c.source.start.executedGTIDs)) {
            failure = $0 as? ArchiveReadError
        }
        let error = try XCTUnwrap(failure)
        XCTAssertEqual(error.coordinate, .init(file: "binlog.000003", position: 1885))
        do {
            let state = try StateStore(configuration: c)
            try state.recordSourceFailure(error.reason, at: error.coordinate)
            try state.block(error.reason)
        }
        let report = try Recovery.inspect(configuration: c)
        XCTAssertNil(report.targetUUID)
        XCTAssertNil(report.appliedPosition)
        XCTAssertEqual(report.sourceFailurePosition, error.coordinate)
        XCTAssertTrue(report.pending.isEmpty)
        XCTAssertEqual(report.recovery?.category, "noPendingTransactions")
        XCTAssertEqual(report.recovery?.requiresTargetReconciliation, false)
        let bundleConfig = try JSONDecoder().decode(
            SupportBundleConfiguration.self,
            from: JSONSerialization.data(withJSONObject: [
                "stateDirectory": path.path, "archive": ["directory": dir.path],
                "supportBundle": [
                    "format": "directory",
                    "output": path.deletingLastPathComponent().appendingPathComponent("bundle").path,
                ],
            ]))
        let bundle = try SupportBundle.run(
            configuration: bundleConfig, redactedConfiguration: Data("{}".utf8), version: "test")
        let bundled = URL(fileURLWithPath: bundle.output)
        let excerpt = try JSONDecoder().decode(
            BinlogExcerpt.Index.self, from: Data(contentsOf: bundled.appendingPathComponent("archive/binlog-0.json")))
        XCTAssertEqual(excerpt.sourceFile, "binlog.000003")
        XCTAssertEqual(excerpt.focusStart, 1885)
        XCTAssertEqual(
            try helper.sqlite(
                bundled.appendingPathComponent("state.sqlite"), "SELECT source_file,source_position FROM source_failure"
            ), [["binlog.000003", "1885"]])
        try original.write(to: file)
        let resolved = try Recovery.resolve(
            configuration: c, action: .retry, gtids: "none", reason: "Operator replaced the invalid archive file")
        XCTAssertEqual(resolved.resumeGTIDSet, c.source.start.executedGTIDs)
        let state = try StateStore(configuration: c, initialize: false)
        XCTAssertNil(state.targetUUID)
        XCTAssertNil(state.applied)
        var ids: [String] = []
        try ArchiveReplay(configuration: archiveConfig, source: c.source, contract: .mysql84).run(
            configuration: state.captureConfiguration(c.source), cancellation: .init(), resumeFrom: state.applied,
            emitEvent: { _ in }, emitTransaction: { ids.append($0.gtid!.sequence) }, resolveSchema: nil,
            timings: .init(), ignoreTable: nil)
        XCTAssertEqual(ids, ["11", "12", "13", "14"])
    }

    func testUnboundRecoveryRequiresEmptyStateAndCurrentSourceFailure() throws {
        for damage in [
            "DELETE FROM source_failure",
            "UPDATE source_failure SET reason='old failure'",
            "UPDATE source_failure SET source_position='bad'",
            "UPDATE state SET transactions_applied=1",
            "INSERT INTO pending_gtid_markers VALUES('00000000-0000-0000-0000-000000000001:1')",
        ] {
            let path = try directory()
            let c = try helper.config(path.path)
            do {
                let state = try StateStore(configuration: c)
                try state.recordSourceFailure("bad event", at: .init(file: "binlog.000003", position: 1885))
                try state.block("bad event")
            }
            try write(path, damage)
            XCTAssertThrowsError(
                try Recovery.resolve(
                    configuration: c, action: .retry, gtids: "none", reason: "must reject invalid state"), damage)
            XCTAssertEqual(
                try helper.sqlite(path.appendingPathComponent("state.sqlite"), "SELECT lifecycle FROM state"),
                [["BLOCKED"]])
        }
    }
}

extension ResumeTests {
    func testMiddleFileRowDecoderFailureReportsPhysicalOffsetAfterValidation() throws {
        let c = try helper.config(try directory().path)
        let (dir, archiveConfig) = try recoveryArchive(c)
        let file = dir.appendingPathComponent("binlog.000003")
        var bytes = try Data(contentsOf: file)
        bytes[2101 + 4] = 0  // Unknown row event; valid physical frame and CRC.
        var crc = ArchiveIO.crc32(Data(bytes[2101..<2178])).littleEndian
        withUnsafeBytes(of: &crc) { bytes.replaceSubrange(2178..<2182, with: $0) }
        try bytes.write(to: file)
        let archive = try ArchiveReplay(configuration: archiveConfig, source: c.source, contract: .mysql84)
        try archive.validate(baseline: c.source.start.executedGTIDs)
        var ids: [String] = []
        XCTAssertThrowsError(
            try archive.run(
                configuration: c.source, cancellation: .init(),
                emitEvent: { _ in }, emitTransaction: { ids.append($0.gtid!.sequence) },
                resolveSchema: nil, timings: .init(), ignoreTable: nil)
        ) {
            XCTAssertEqual(($0 as? ArchiveReadError)?.coordinate, .init(file: "binlog.000003", position: 2101))
        }
        XCTAssertEqual(ids, ["11"])
    }
}
