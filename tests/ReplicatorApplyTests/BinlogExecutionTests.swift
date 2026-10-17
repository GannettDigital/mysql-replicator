import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ApplyTests {
    func testBinlogCaptureKeepsFixtureBytesAndRejectsMissingOrOversizedRawGroups() throws {
        let data = try Data(
            contentsOf: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
        let length = (0..<4).reduce(0) { $0 | Int(data[4 + 9 + $1]) << (8 * $1) }
        let fde = data.subdata(in: 4..<4 + length)
        let format = LiveRecord(
            kind: "formatContext", file: "binlog.000003", observedPosition: "4",
            event: nil, rawBase64: nil, rawBytes: fde)
        var capture = BinlogGroupCapture(maximumRawBytes: 1024 * 1024)
        capture.append(format)
        for group in try groups() {
            for event in group.events {
                capture.append(
                    LiveRecord(
                        kind: "event", file: group.start.file, observedPosition: String(event.nextPosition),
                        event: event, rawBase64: event.rawBase64))
            }
            let program = try capture.prepare(
                group, mutations: DMLPlan.make(group, tables: tables()),
                maximumPacketBytes: 1024 * 1024, transactional: true, preserveSourceGTIDs: true)
            XCTAssertEqual(
                program.rows.events,
                group.events.filter { [19, 30, 31, 32].contains(Int($0.eventType)) }
                    .map { Data(base64Encoded: $0.rawBase64!)! })
            capture.resetGroup()
        }
        let group = try groups()[0]
        for limit in [1, 1024 * 1024] {
            var invalid = BinlogGroupCapture(maximumRawBytes: limit)
            invalid.append(format)
            for event in group.events {
                invalid.append(
                    LiveRecord(
                        kind: "event", file: group.start.file, observedPosition: String(event.nextPosition),
                        event: event, rawBase64: limit == 1 ? event.rawBase64 : nil))
            }
            XCTAssertThrowsError(
                try invalid.prepare(
                    group, mutations: DMLPlan.make(group, tables: tables()),
                    maximumPacketBytes: 1024 * 1024, transactional: true, preserveSourceGTIDs: true))
        }
    }
    func testBinlogJournalPrecedesWritesAndCompletesOnlyAfterCommit() throws {
        try withBatchFixture { state, groups in
            try state.beginBatch(groups)
            var calls: [String] = []
            let outcome = BinlogExecution.run(
                groups, transactional: true, cancellation: .init(),
                prepare: { _ in
                    XCTAssertEqual(
                        try self.sqlite(
                            state.directory.appendingPathComponent("state.sqlite"),
                            "SELECT COUNT(*) FROM row_intents WHERE status='PENDING'"), [["4"]])
                    calls.append("prepare")
                }, begin: { calls.append("begin") }, write: { _ in calls.append("binlog") },
                commit: {
                    calls.append("commit")
                    XCTAssertEqual(state.transactions, 0)
                }, rollback: { XCTFail() },
                finish: { calls.append("reset") }, skippedGTID: { _ in XCTFail() },
                resetTrace: {}, trace: { .init(phase: .acknowledged) })
            XCTAssertNil(outcome.failure)
            XCTAssertEqual(
                calls, Array(repeating: ["prepare", "begin", "binlog", "commit", "reset"], count: 4).flatMap { $0 })
            try outcome.record(in: state)
            XCTAssertEqual(state.transactions, 4)
        }
    }

    func testBinlogLostCommitStopsWithoutRollbackOrRetry() throws {
        try withBatchFixture { state, groups in
            try state.beginBatch(groups)
            var writes = 0
            var commits = 0
            let outcome = BinlogExecution.run(
                groups, transactional: true, cancellation: .init(),
                prepare: { _ in }, begin: {}, write: { _ in writes += 1 },
                commit: {
                    commits += 1
                    if commits == 2 { throw TargetConnectionFailure(description: "lost commit") }
                },
                rollback: { XCTFail("A later rollback cannot disprove COMMIT") }, finish: {},
                skippedGTID: { _ in XCTFail() }, resetTrace: {},
                trace: { .init(phase: .possiblyExecuted, sql: "COMMIT") })
            XCTAssertEqual(writes, 2)
            XCTAssertEqual(outcome.acknowledged, [1, 0, 0, 0])
            XCTAssertEqual(outcome.diagnostic?.transactionOutcome, "commitUncertain")
            XCTAssertFalse(outcome.discardUnwritten)
            XCTAssertThrowsError(try outcome.record(in: state))
            XCTAssertEqual(state.transactions, 1)
            XCTAssertEqual(state.pendingGTID, groups[1].id)
        }
    }

    func testBinlogDuplicateRollsBackOnlyOnInnoDBAndNeverFallsBack() throws {
        for transactional in [false, true] {
            try withBatchFixture { _, groups in
                var writes = 0
                var rollbacks = 0
                let outcome = BinlogExecution.run(
                    groups, transactional: transactional, cancellation: .init(),
                    prepare: { _ in }, begin: {},
                    write: { _ in
                        writes += 1
                        throw ApplyError("duplicate", code: .duplicateKey, mysqlErrorNumber: 1062)
                    }, commit: { XCTFail() }, rollback: { rollbacks += 1 }, finish: {},
                    skippedGTID: { _ in XCTFail() }, resetTrace: {}, trace: { .init(phase: .possiblyExecuted) })
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(rollbacks, transactional ? 1 : 0)
                XCTAssertEqual(outcome.acknowledged, [0, 0, 0, 0])
                XCTAssertEqual(
                    outcome.diagnostic?.transactionOutcome, transactional ? "rolledBack" : "possiblyExecuted")
                XCTAssertFalse(outcome.discardUnwritten)
            }
        }
    }

    func testBinlogSkipRequiresConfirmedInnoDBRollback() throws {
        for transactional in [false, true] {
            try withBatchFixture(
                profile: transactional ? "mysql57-to-mysql84-innodb" : nil, skipErrors: ["codes": ["mysql.1062"]]
            ) { state, input in
                let groups = Array(input.prefix(1))
                try state.beginBatch(groups)
                var markers = 0
                var policy = SkipErrorPolicy()
                policy.codes = [.duplicateKey]
                let outcome = BinlogExecution.run(
                    groups, transactional: transactional, cancellation: .init(),
                    skipErrors: policy, prepare: { _ in }, begin: {},
                    write: { _ in
                        throw ApplyError("duplicate", code: .duplicateKey, mysqlErrorNumber: 1062)
                    }, commit: { XCTFail() }, rollback: {}, finish: {}, skippedGTID: { _ in markers += 1 },
                    resetTrace: {}, trace: { .init(phase: .possiblyExecuted) })
                XCTAssertEqual(markers, transactional ? 1 : 0)
                XCTAssertEqual(outcome.skipped.count, transactional ? 1 : 0)
                if transactional {
                    try outcome.record(in: state)
                    XCTAssertEqual(state.transactions, 1)
                } else {
                    XCTAssertNotNil(outcome.failure)
                }
            }
        }
    }

    func testBinlogRollbackLossDoesNotPermitSkip() throws {
        try withBatchFixture { _, groups in
            var policy = SkipErrorPolicy()
            policy.codes = [.duplicateKey]
            let outcome = BinlogExecution.run(
                groups, transactional: true, cancellation: .init(),
                skipErrors: policy, prepare: { _ in }, begin: {},
                write: { _ in
                    throw ApplyError("duplicate", code: .duplicateKey, mysqlErrorNumber: 1062)
                }, commit: {}, rollback: { throw TargetConnectionFailure(description: "lost rollback") },
                finish: {}, skippedGTID: { _ in XCTFail() }, resetTrace: {}, trace: { .init(phase: .possiblyExecuted) })
            XCTAssertEqual(outcome.diagnostic?.transactionOutcome, "rollbackUnconfirmed")
            XCTAssertTrue(outcome.skipped.isEmpty)
        }
    }

    func testBinlogConnectionLossBeforeBeginCanReconnectWithoutRowReplay() throws {
        try withBatchFixture { _, groups in
            let outcome = BinlogExecution.run(
                groups, transactional: true, cancellation: .init(),
                prepare: { _ in throw TargetConnectionFailure(description: "FDE request lost") },
                begin: { XCTFail() }, write: { _ in XCTFail() }, commit: { XCTFail() },
                rollback: { XCTFail() }, finish: {}, skippedGTID: { _ in XCTFail() },
                resetTrace: {}, trace: { .init() })
            XCTAssertTrue(outcome.discardUnwritten)
            XCTAssertEqual(outcome.diagnostic?.transactionOutcome, "notStarted")
        }
    }

    func testBinlogTransportBindingRejectsChangesAndMigratesOnlyLegacySQL() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for transport in ["sql", "binlog"] {
            let path = parent.appendingPathComponent(transport).path
            let configuration = try config(path, transport: transport)
            do {
                let state = try StateStore(configuration: configuration)
                try state.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
                try state.running()
                try state.stopped()
            }
            XCTAssertNoThrow(try StateStore(configuration: configuration, initialize: false))
            XCTAssertThrowsError(
                try StateStore(
                    configuration: config(path, transport: transport == "sql" ? "binlog" : "sql"), initialize: false))
            let db = URL(fileURLWithPath: path).appendingPathComponent("state.sqlite")
            XCTAssertEqual(try sqlite(db, "SELECT mode,program_version FROM target_transport"), [[transport, "1"]])
            if transport == "sql" {
                try writeGTIDTestState(db, "DROP TABLE target_transport; PRAGMA user_version=13")
                XCTAssertThrowsError(
                    try StateStore(configuration: config(path, transport: "binlog"), initialize: false))
                XCTAssertNoThrow(try StateStore(configuration: configuration, initialize: false))
                XCTAssertEqual(try sqlite(db, "PRAGMA user_version"), [["14"]])
            }
        }
    }
}
