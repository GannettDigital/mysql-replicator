import Foundation
import ReplicatorCapture
import ReplicatorCodec
import XCTest

@testable import ReplicatorApply

final class ApplyValidationTests: XCTestCase {
    private let uuid = "8ba09bde-bc41-11f1-8272-ba06e9024a03"
    private func fixture(_ body: (URL, ApplyConfiguration, ArchiveConfiguration) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/tmp/validate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),
            to: archive.appendingPathComponent("binlog.000003"))
        let config = try JSONDecoder().decode(
            ApplyConfiguration.self,
            from: JSONSerialization.data(withJSONObject: [
                "version": 2, "stateDirectory": directory.appendingPathComponent("state").path,
                "source": [
                    "version": 2, "host": "unused.invalid", "port": 3306, "username": "unused",
                    "requireTLS": true, "serverHostname": "unused.invalid", "caFile": "/missing-source-ca.pem",
                    "passwordEnvironment": "MISSING_VALIDATION_SOURCE_SECRET_1792538", "serverID": 9100,
                    "sourceUUID": uuid, "mode": "gtid", "start": ["executedGTIDs": uuid + ":1-10"],
                ],
                "target": [
                    "unixSocket": "/tmp/absent-" + UUID().uuidString + ".sock", "username": "unused",
                    "password": "validation-secret", "requireTLS": false, "preserveSourceGTIDs": false,
                    "nativeAutoStartDisabled": true,
                ],
            ]))
        let inventory = try JSONDecoder().decode(
            ArchiveConfiguration.self,
            from: JSONSerialization.data(withJSONObject: ["directory": archive.path]))
        try body(directory, config, inventory)
    }
    private var connections: ApplyValidation.Connections {
        .init(
            target: { _, _, report in
                report.check("target.test", nextStep: "unused") { "Injected target check." }
            }, source: { _, _, _ in XCTFail("Replay must not connect to the source") })
    }
    func testReplayDoesNotResolveSourceCredentialsOrReadSourceTLSOrOpenState() throws {
        try fixture { directory, config, archive in
            let report = ApplyValidation.run(
                configuration: config, offline: true, archive: archive, connections: connections)
            let output = try JSONEncoder().encode(report)
            XCTAssertTrue(report.ok, String(decoding: output, as: UTF8.self))
            XCTAssertEqual(report.checks.first { $0.name == "archive" }?.status, "passed")
            XCTAssertEqual(report.checks.first { $0.name == "source.connection" }?.status, "notChecked")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["archive"])
        }
    }
    func testTargetFailurePrecedesArchiveReadsAndRedactsResolvedSecret() throws {
        try fixture { directory, config, archive in
            try FileManager.default.removeItem(atPath: archive.directory)
            var probes = connections
            probes.target = { _, password, report in
                report.check("target.connection", nextStep: "Check credentials.") {
                    throw ApplyError("Rejected " + password)
                }
            }
            let report = ApplyValidation.run(
                configuration: config, offline: true, archive: archive, connections: probes)
            XCTAssertFalse(report.ok)
            XCTAssertEqual(report.checks.first { $0.name == "archive" }?.status, "notChecked")
            XCTAssertFalse(
                String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("validation-secret"))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
    func testRunRequiresSourceCredentialsAndTLSBeforeConnections() throws {
        try fixture { _, config, _ in
            var probes = connections
            probes.target = { _, _, _ in XCTFail("Local failure must precede target connection") }
            let report = ApplyValidation.run(configuration: config, offline: false, archive: nil, connections: probes)
            XCTAssertFalse(report.ok)
            XCTAssertEqual(report.checks.first { $0.name == "source.credentials" }?.status, "failed")
            XCTAssertEqual(report.checks.first { $0.name == "source.tls" }?.status, "failed")
        }
    }
    func testArchiveChecksEveryPreambleButDoesNotScanRows() throws {
        try fixture { _, config, archive in
            let file = URL(fileURLWithPath: archive.directory).appendingPathComponent("binlog.000003")
            var bytes = try Data(contentsOf: file)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: file)
            let report = ApplyValidation.run(
                configuration: config, offline: true, archive: archive, connections: connections)
            XCTAssertTrue(report.ok)
            XCTAssertEqual(report.checks.first { $0.name == "archive.events" }?.status, "notChecked")
            let replay = try ArchiveReplay(configuration: archive, source: config.source, contract: .mysql84)
            XCTAssertThrowsError(try replay.validate(baseline: config.source.start.executedGTIDs))
            // Inventory reads the first FDE. Validation must also inspect later files.
            try Data([0, 1, 2, 3]).write(to: file.deletingLastPathComponent().appendingPathComponent("binlog.000004"))
            let failed = ApplyValidation.run(
                configuration: config, offline: true, archive: archive, connections: connections)
            XCTAssertFalse(failed.ok)
            XCTAssertEqual(failed.checks.first { $0.name == "archive" }?.status, "failed")
        }
    }
    func testDirectoryProbePreservesExistingFilesAndRemovesTemporaryFiles() throws {
        try fixture { directory, _, _ in
            let sentinel = directory.appendingPathComponent("state.sqlite")
            let bytes = Data("do not open as SQLite".utf8)
            try bytes.write(to: sentinel)
            _ = try ValidationDirectory.probe(directory, minimumFreeBytes: 1)
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["archive", "state.sqlite"])
            XCTAssertThrowsError(try ValidationDirectory.probe(sentinel, minimumFreeBytes: 1))
            XCTAssertThrowsError(try ValidationDirectory.probe(directory, minimumFreeBytes: Int64.max))
        }
    }
}
