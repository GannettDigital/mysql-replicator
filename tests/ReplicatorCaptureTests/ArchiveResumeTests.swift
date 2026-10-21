import Foundation
import ReplicatorCodec
import XCTest

@testable import ReplicatorCapture

extension ArchiveTests {
    private final class ValidationRecords {
        var records: [String: Data] = [:]
        var persistence: ArchiveValidationPersistence {
            ArchiveValidationPersistence(
                prepare: { paths in self.records = self.records.filter { paths.contains($0.key) } },
                load: { self.records[$0] }, save: { self.records[$0] = $1 })
        }
    }

    /// Split the real fixture at transaction boundaries. Each file has a format
    /// event, cumulative Previous_gtids, and a physical ROTATE to the next file.
    private func splitArchive(_ dir: URL, sid: String) throws {
        var format = Data()
        var groups: [UInt64: [Data]] = [:]
        var sequence: UInt64 = 0
        try ArchiveFileReader(file: dir.appendingPathComponent("binlog.000003"), maximumEventBytes: 1 << 26).scan {
            frame, _ in
            switch frame[4] {
            case 15: format = frame
            case 35, 4: break
            default:
                if frame[4] == 33 { sequence = ArchiveIO.read(frame, at: 36, as: UInt64.self) }
                groups[sequence, default: []].append(frame)
            }
        }
        for (index, range) in [UInt64(6)...10, UInt64(11)...12, UInt64(13)...14].enumerated() {
            var bytes = Data([0xfe, 0x62, 0x69, 0x6e])
            func append(_ source: Data) {
                var frame = source
                var next = UInt32(bytes.count + frame.count).littleEndian
                withUnsafeBytes(of: &next) { frame.replaceSubrange(13..<17, with: $0) }
                frame[17] &= ~0x20
                var crc = ArchiveIO.crc32(Data(frame.dropLast(4)), format: frame[4] == 15).littleEndian
                withUnsafeBytes(of: &crc) { frame.replaceSubrange(frame.count - 4..<frame.count, with: $0) }
                bytes.append(frame)
            }
            append(format)
            let prior = try GTIDSet(sid + ":1-\(range.lowerBound - 1)")
            append(ArchiveIO.pseudo(type: 35, position: 0, body: Data(prior.encoded().readableBytesView)))
            for n in range { for frame in try XCTUnwrap(groups[n]) { append(frame) } }
            append(ArchiveIO.announce(String(format: "binlog.%06d", index + 4)))
            try bytes.write(to: dir.appendingPathComponent(String(format: "binlog.%06d", index + 3)))
        }
    }

    func testReplaySelectsFileFromPreviousGTIDsAndPreservesHoles() throws {
        try fixture { dir, source, config in
            try splitArchive(dir, sid: source.sourceUUID)
            var progress: [ArchiveReplay.Progress] = []
            let archive = try ArchiveReplay(
                configuration: config, source: source, contract: .mysql84, progress: { progress.append($0) })
            for (baseline, expected, firstFile) in [
                (":1-10", ["11", "12", "13", "14"], "binlog.000004"),
                (":1-12", ["13", "14"], "binlog.000005"),
                (":1-11:13", ["12", "14"], "binlog.000004"),
                (":1-14", [], "binlog.000005"),
            ] {
                let resumed = source.resuming(file: nil, position: nil, executedGTIDs: source.sourceUUID + baseline)
                var groups: [String] = []
                var files: [String] = []
                progress = []
                try archive.run(
                    configuration: resumed, cancellation: .init(),
                    emitEvent: { record in files.append(record.file) },
                    emitTransaction: { groups.append($0.gtid!.sequence) }, resolveSchema: nil,
                    timings: .init(), ignoreTable: nil)
                XCTAssertEqual(groups, expected)
                XCTAssertEqual(files.first, firstFile)
                XCTAssertFalse(files.contains("binlog.000003"))
                let read = try XCTUnwrap(progress.last)
                XCTAssertEqual(read.phase, "replay_read")
                XCTAssertEqual(
                    read.bytesRead, archive.manifest.files.filter { $0.name >= firstFile }.reduce(0) { $0 + $1.bytes })
                XCTAssertEqual(read.preambleBytesRead, 0)
                XCTAssertLessThan(read.bytesRead + read.preambleBytesRead, read.bytesTotal)
            }
        }
    }

    func testPersistentValidationReusesOnlyCompleteFilesAfterCancellation() throws {
        try fixture { dir, source, config in
            try splitArchive(dir, sid: source.sourceUUID)
            let cache = ValidationRecords()
            var cancel = false
            let interrupted = try ArchiveReplay(
                configuration: config, source: source, contract: .mysql84,
                progress: { if $0.filesCompleted == 1 { cancel = true } })
            XCTAssertThrowsError(
                try interrupted.validate(
                    baseline: source.start.executedGTIDs, persistence: cache.persistence, isCancelled: { cancel })
            ) {
                XCTAssertTrue($0 is CaptureCancelled)
            }
            XCTAssertEqual(cache.records.count, 1)
            var progress: [ArchiveReplay.Progress] = []
            func fresh() throws -> ArchiveReplay {
                try ArchiveReplay(
                    configuration: config, source: source, contract: .mysql84, progress: { progress.append($0) })
            }
            let resumed = try fresh()
            try resumed.validate(baseline: source.start.executedGTIDs, persistence: cache.persistence)
            XCTAssertEqual(cache.records.count, 3)
            XCTAssertEqual(progress.filter { $0.phase == "validation_file_reused" }.map(\.file), ["binlog.000003"])
            XCTAssertEqual(progress.last?.bytesRead, resumed.manifest.files.dropFirst().reduce(0) { $0 + $1.bytes })
            progress = []
            let warm = try fresh()
            try warm.validate(baseline: source.start.executedGTIDs, persistence: cache.persistence)
            XCTAssertEqual(warm.availableGTIDs, source.sourceUUID + ":1-14")
            XCTAssertEqual(progress.filter { $0.phase == "validation_file_reused" }.count, 3)
            XCTAssertEqual(progress.last?.bytesRead, 0)
            XCTAssertEqual(progress.last?.preambleBytesRead, 0)
            XCTAssertThrowsError(try fresh().validate(baseline: "", persistence: cache.persistence))
            XCTAssertThrowsError(
                try fresh().validate(
                    baseline: source.start.executedGTIDs, stopAfterGTIDs: source.sourceUUID + ":99",
                    persistence: cache.persistence))
            // Cached records must still enforce file ordering and rotation.
            let reordered = try JSONDecoder().decode(
                ArchiveConfiguration.self,
                from: JSONSerialization.data(withJSONObject: [
                    "directory": dir.path, "files": ["binlog.000003", "binlog.000005", "binlog.000004"],
                ]))
            XCTAssertThrowsError(
                try ArchiveReplay(configuration: reordered, source: source, contract: .mysql84).validate(
                    baseline: source.start.executedGTIDs, persistence: cache.persistence))
        }
    }

    func testPersistentValidationRejectsChangedFilesAndRescansInvalidRecords() throws {
        try fixture { dir, source, config in
            let cache = ValidationRecords()
            var progress: [ArchiveReplay.Progress] = []
            func validate() throws {
                progress = []
                try ArchiveReplay(
                    configuration: config, source: source, contract: .mysql84, progress: { progress.append($0) }
                )
                .validate(baseline: source.start.executedGTIDs, persistence: cache.persistence)
            }
            try validate()
            let file = dir.appendingPathComponent("binlog.000003")
            let record = try XCTUnwrap(cache.records[file.path])
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
            old["version"] = 0
            var differentLimit = old
            differentLimit["version"] = 1
            differentLimit["maximumEventBytes"] = 1
            for invalid in [
                Data("bad json".utf8), try JSONSerialization.data(withJSONObject: old),
                try JSONSerialization.data(withJSONObject: differentLimit),
            ] {
                cache.records[file.path] = invalid
                try validate()
                XCTAssertEqual(progress.last?.bytesRead, try ArchiveIO.regularFile(file))
                XCTAssertFalse(progress.contains { $0.phase == "validation_file_reused" })
            }
            let original = try Data(contentsOf: file)
            try original.write(to: file, options: .atomic)
            try validate()
            XCTAssertEqual(progress.last?.bytesRead, UInt64(original.count))
            var corrupt = original
            corrupt[corrupt.count - 1] ^= 1
            try corrupt.write(to: file)
            XCTAssertThrowsError(try validate()) { XCTAssertTrue(String(describing: $0).contains("CRC")) }
            try original.dropLast().write(to: file)
            XCTAssertThrowsError(try validate())
        }
    }
}

extension ArchiveTests {
    func testReplaySeeksToDurableOffsetAfterReadingFormatAndPreviousGTIDs() throws {
        try fixture { dir, source, config in
            let cache = ValidationRecords()
            let cold = try ArchiveReplay(configuration: config, source: source, contract: .mysql84)
            try cold.validate(baseline: source.start.executedGTIDs, persistence: cache.persistence)
            for (baseline, offset, expected) in [
                (":1-12", UInt64(2213), ["13", "14"]),
                (":1-11:13", UInt64(1885), ["12", "14"]),
                (":1-14", UInt64(2841), []),
                (":1-14", UInt64(2885), []),
            ] {
                var progress: [ArchiveReplay.Progress] = []
                let archive = try ArchiveReplay(
                    configuration: config, source: source, contract: .mysql84, progress: { progress.append($0) })
                let resumed = source.resuming(
                    file: "binlog.000003", position: UInt32(offset), executedGTIDs: source.sourceUUID + baseline)
                let checkpoint = BinlogCoordinate(file: "binlog.000003", position: offset)
                try archive.validate(
                    baseline: resumed.start.executedGTIDs, resumeFrom: checkpoint, persistence: cache.persistence)
                XCTAssertEqual(progress.last?.bytesRead, 0)
                var groups: [CompleteTransaction] = []
                try archive.run(
                    configuration: resumed, cancellation: .init(), retainRawBytes: true, resumeFrom: checkpoint,
                    emitEvent: { _ in }, emitTransaction: { groups.append($0) }, resolveSchema: nil, timings: .init(),
                    ignoreTable: nil)
                XCTAssertEqual(groups.map { $0.gtid!.sequence }, expected)
                XCTAssertEqual(progress.last?.bytesRead, 198 + 2885 - offset)
                XCTAssertEqual(progress.last?.preambleBytesRead, 0)
            }
        }
    }

    func testColdValidationChecksResumeBoundaryAndPrefixCoverage() throws {
        try fixture { _, source, config in
            for (baseline, offset, reason) in [
                (":1-11:13", UInt64(2509), "skips unapplied"),
                (":1-12", UInt64(2214), "complete transaction boundary"),
            ] {
                let archive = try ArchiveReplay(configuration: config, source: source, contract: .mysql84)
                XCTAssertThrowsError(
                    try archive.validate(
                        baseline: source.sourceUUID + baseline,
                        resumeFrom: .init(file: "binlog.000003", position: offset))
                ) {
                    XCTAssertTrue(String(describing: $0).contains(reason), String(describing: $0))
                }
            }
            let archive = try ArchiveReplay(configuration: config, source: source, contract: .mysql84)
            var groups: [String] = []
            let resumed = source.resuming(
                file: "binlog.000003", position: 2213, executedGTIDs: source.sourceUUID + ":1-12")
            try archive.run(
                configuration: resumed, cancellation: .init(), resumeFrom: .init(file: "binlog.000003", position: 2213),
                emitEvent: { _ in }, emitTransaction: { groups.append($0.gtid!.sequence) }, resolveSchema: nil,
                timings: .init(), ignoreTable: nil)
            XCTAssertEqual(groups, ["13", "14"])
        }
    }

    func testReplaySeekMaintainsHistoryAcrossRotation() throws {
        try fixture { dir, source, config in
            try splitArchive(dir, sid: source.sourceUUID)
            var progress: [ArchiveReplay.Progress] = []
            let archive = try ArchiveReplay(
                configuration: config, source: source, contract: .mysql84, progress: { progress.append($0) })
            let resumed = source.resuming(
                file: "binlog.000004", position: 494, executedGTIDs: source.sourceUUID + ":1-11")
            var groups: [String] = []
            try archive.run(
                configuration: resumed, cancellation: .init(), resumeFrom: .init(file: "binlog.000004", position: 494),
                emitEvent: { _ in }, emitTransaction: { groups.append($0.gtid!.sequence) }, resolveSchema: nil,
                timings: .init(), ignoreTable: nil)
            XCTAssertEqual(groups, ["12", "13", "14"])
            XCTAssertEqual(
                progress.last?.bytesRead, 198 + archive.manifest.files.dropFirst().reduce(0) { $0 + $1.bytes } - 494)
        }
    }
}
