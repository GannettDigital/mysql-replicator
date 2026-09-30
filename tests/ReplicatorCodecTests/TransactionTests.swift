import XCTest
import Foundation
@testable import ReplicatorCodec
import ReplicatorLabCore
import CReplicatorCodec

final class TransactionTests: XCTestCase, BinlogFixtures {
    let sourceFile = "binlog.000003"
    func records(_ name: String = "source-positive") throws -> [DecodedEvent] {
        var events: [DecodedEvent] = []
        try Inspection.inspect(file: recorded.appendingPathComponent(name + ".binlog"), history: schema(name)) { events.append($0) }
        return events
    }
    func transactionFailure(_ code: TransactionError.Code, file: StaticString = #filePath, line: UInt = #line,
                            _ work: () throws -> Void) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual((error as? TransactionError)?.code, code, String(describing: error), file: file, line: line)
        }
    }
    func query(_ sql: String, error: UInt16 = 0, status: Data = Data()) -> Data {
        le(UInt32(1)) + le(UInt32(0)) + Data([0]) + le(error) + le(UInt16(status.count)) + status + Data([0]) + Data(sql.utf8)
    }
    func gtid(_ sequence: UInt64 = 1, anonymous: Bool = false) -> Data {
        // MySQL 5.6 traditional GTID body (no optional logical-clock fields).
        Data([0]) + Data(repeating: anonymous ? 0 : 0xab, count: 16) + le(sequence)
    }
    func synthetic(_ bodies: [(UInt8, Data)]) throws -> [DecodedEvent] {
        let fde = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let decoder = try BinlogDecoder()
        var result = [try decoder.decode(fde, at: 4)], offset = UInt64(fde.count + 4)
        for (type, body) in bodies {
            let frame = event(type, body, at: offset)
            result.append(try decoder.decode(frame, at: offset)); offset += UInt64(frame.count)
        }
        return result
    }
    func assemble(_ events: [DecodedEvent], limits: TransactionAssembler.Limits = .init()) throws -> [CompleteTransaction] {
        let assembler = try TransactionAssembler(file: sourceFile, limits: limits)
        var groups: [CompleteTransaction] = []
        for event in events {
            if let group = try assembler.consume(event, file: sourceFile) { groups.append(group) }
        }
        try assembler.finish()
        return groups
    }
    // Preserve decoded payload while testing corrupt coordinate/statement flags.
    func replacing(_ e: DecodedEvent, offset: UInt64? = nil, next: UInt32? = nil, rowFlags: UInt32? = nil) -> DecodedEvent {
        DecodedEvent(offset: offset.map(String.init) ?? e.offset, eventSize: e.eventSize, control: e.control,
            rowFlags: rowFlags ?? e.rowFlags, eventType: e.eventType, eventName: e.eventName,
            timestamp: e.timestamp, serverID: e.serverID, nextPosition: next ?? e.nextPosition,
            flags: e.flags, sha256: e.sha256, tableID: e.tableID, database: e.database, table: e.table,
            number: e.number, detailBase64: e.detailBase64, detailText: e.detailText, rows: e.rows, rawBase64: e.rawBase64)
    }
    func testRecordedSourceBoundariesMatchIndependentMySQLText() throws {
        let events = try records(), groups = try assemble(events)
        // Exact positions/GTIDs from committed mysqlbinlog text, not our codec.
        XCTAssertEqual(groups.map(\.start.position), [198,525,759,990,1270,1589,1885,2213,2509])
        XCTAssertEqual(groups.map(\.end.position), [525,759,990,1270,1589,1885,2213,2509,2841])
        XCTAssertEqual(groups.map { $0.gtid?.sequence }, (6...14).map { String($0) })
        XCTAssertTrue(groups.allSatisfy { $0.gtid?.sid == "8ba09bde-bc41-11f1-8272-ba06e9024a03" })
        XCTAssertEqual(groups.map(\.outcome), Array(repeating: .statement, count: 4) + Array(repeating: .committed, count: 5))
        XCTAssertEqual(groups.suffix(4).map { $0.events.flatMap(\.rows).count }, [1,1,1,1])
        XCTAssertEqual(groups.suffix(4).flatMap { $0.events.flatMap(\.rows).map(\.operation) }, ["insert","update","delete","update"])
        XCTAssertEqual(groups.suffix(4).map { $0.events.last?.control }, [.xid("61"), .xid("62"), .xid("63"), .xid("67")])
        let boundary = try Inspection.inspectTransactions(file: recorded.appendingPathComponent("source-positive.binlog"), sourceFile: sourceFile, history: schema("source-positive")) { _ in }
        XCTAssertEqual(boundary, BinlogCoordinate(file: "binlog.000004", position: 4))
    }
    func testNativeQueryCommitsAndAnonymousIdentityStayDistinct() throws {
        for name in ["native-positive", "native-rejected"] {
            let end: UInt64 = name == "native-positive" ? 2418 : 1357
            let groups = try assemble(records(name).filter { UInt64($0.offset)! < end })
            XCTAssertTrue(groups.contains { $0.anonymous && $0.gtid == nil })
            let workload = groups.filter { $0.start.position >= 1020 && $0.end.position <= (name == "native-positive" ? 2418 : 1357) }
            XCTAssertEqual(workload.count, name == "native-positive" ? 4 : 1)
            XCTAssertTrue(workload.allSatisfy { $0.gtid != nil && !$0.anonymous && $0.outcome == .committed })
            XCTAssertTrue(workload.allSatisfy {
                if case .query(let query) = $0.events.last?.control { return query.sql == Data("COMMIT".utf8) }
                return false
            })
        }
    }
    func testStatementEndDoesNotAdvanceTransactionBoundary() throws {
        let assembler = try TransactionAssembler(file: sourceFile)
        for e in try records() where UInt64(e.offset)! < 1885 {
            let group = try assembler.consume(e, file: sourceFile)
            if UInt64(e.offset)! >= 1589 && e.eventType != 16 {
                XCTAssertNil(group)
                XCTAssertEqual(assembler.lastCompleteBoundary?.position, 1589)
            }
            if e.rowFlags == 1 && e.offset == "1796" {
                XCTAssertEqual(assembler.pendingTransactionStart?.position, 1589)
            }
        }
        XCTAssertEqual(assembler.lastCompleteBoundary?.position, 1885)
        XCTAssertNil(assembler.pendingTransactionStart)
    }
    func testEOFAtEveryIncompleteGroupFrameKeepsPreviousBoundary() throws {
        let events = try records()
        for end in [1668,1739,1796,1854] {
            let assembler = try TransactionAssembler(file: sourceFile)
            var completed: [CompleteTransaction] = []
            for e in events where UInt64(e.offset)! < end {
                if let t = try assembler.consume(e, file: sourceFile) { completed.append(t) }
            }
            XCTAssertEqual(completed.last?.end.position, 1589)
            transactionFailure(.incomplete) { try assembler.finish() }
            XCTAssertEqual(assembler.pendingTransactionStart?.position, 1589)
            XCTAssertEqual(assembler.lastCompleteBoundary?.position, 1589)
            transactionFailure(.poisoned) { try assembler.finish() }
        }
    }
    func testMultiStatementTransactionWaitsForFinalXID() throws {
        // Splice two real autocommit statement bodies under one GTID/BEGIN;
        // retain the second table map and relocate all physical coordinates.
        let original = try records()
        var selected = original.filter { UInt64($0.offset)! < 1854 }
        selected += original.filter { UInt64($0.offset)! >= 2044 && UInt64($0.offset)! < 2213 }
        var relocated: [DecodedEvent] = [], offset: UInt64 = 4
        for e in selected {
            relocated.append(replacing(e, offset: offset, next: UInt32(offset) + e.eventSize)); offset += UInt64(e.eventSize)
        }
        let groups = try assemble(relocated)
        XCTAssertEqual(groups.last?.start.position, 1589)
        XCTAssertEqual(groups.last?.events.flatMap(\.rows).map(\.operation), ["insert", "update"])
        XCTAssertEqual(groups.count, 6)
    }
    func testEmptyCommitRollbackAndLegacyNoGTID() throws {
        let identities: [[(UInt8, Data)]] = [[], [(33, gtid())], [(34, gtid(0, anonymous: true))]]
        for (ending, outcome): (String, CompleteTransaction.Outcome) in [("COMMIT", .committed), ("ROLLBACK", .rolledBack)] {
            for identity in identities {
                let groups = try assemble(synthetic(identity + [(2,query("BEGIN")), (2,query(ending))]))
                XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].outcome, outcome)
                XCTAssertEqual(groups[0].anonymous, identity.first?.0 == 34)
                XCTAssertEqual(groups[0].gtid != nil, identity.first?.0 == 33)
            }
        }
        let groups = try assemble(synthetic([(33,gtid(UInt64(Int64.max)-1)), (2,query("BEGIN")), (16,le(UInt64.max))]))
        XCTAssertEqual(groups[0].gtid?.sequence, "9223372036854775806")
        XCTAssertEqual(groups[0].events.last?.control, .xid("18446744073709551615"))
    }
    func testInvalidControlSequencesPoisonAndPublishNoGroup() throws {
        let cases: [[(UInt8,Data)]] = [
            [(33,gtid()), (33,gtid(2))], [(2,query("BEGIN")), (2,query("BEGIN"))],
            [(2,query("COMMIT"))], [(2,query("ROLLBACK"))], [(16,le(UInt64(1)))],
            [(33,gtid()), (16,le(UInt64(1)))],
            [(2,query("BEGIN")), (4,le(UInt64(4)) + Data("binlog.000004".utf8))],
            [(2,query("BEGIN")), (3,Data())]
        ]
        for body in cases {
            let assembler = try TransactionAssembler(file: sourceFile)
            transactionFailure(.sequence) {
                for e in try synthetic(body) {
                    let group = try assembler.consume(e, file: sourceFile)
                    XCTAssertNil(group)
                }
            }
            XCTAssertEqual(assembler.lastCompleteBoundary?.position, 127)
            transactionFailure(.poisoned) { try assembler.finish() }
        }
    }
    func testUnsupportedQueriesNeverBecomeFalseCommits() throws {
        for sql in ["ROLLBACK TO SAVEPOINT x", "XA START 'x'", "COMMIT AND CHAIN", "BEGIN;", "begin", "/* x */ COMMIT", ""] {
            transactionFailure(.unsupported) { _ = try assemble(synthetic([(33,gtid()), (2,query(sql))])) }
        }
        transactionFailure(.unsupported) { _ = try assemble(synthetic([(2,query("BEGIN")), (2,query("ALTER TABLE t ADD x INT"))])) }
        transactionFailure(.unsupported) { _ = try assemble(synthetic([(2,query("CREATE TABLE t (id INT)", error: 1050))])) }
        let assembler = try TransactionAssembler(file: sourceFile)
        for e in try records() where UInt64(e.offset)! < 1854 { _ = try assembler.consume(e, file: sourceFile) }
        // A ROLLBACK after rows may retain nontransactional effects; never discard.
        let rollback = try synthetic([(2,query("ROLLBACK"))]).last!
        transactionFailure(.unsupported) { _ = try assembler.consume(replacing(rollback, offset: 1854, next: 1854 + rollback.eventSize), file: sourceFile) }
    }
    func testCommitBeforeStatementEndAndUnknownRowFlagsFail() throws {
        for flag: UInt32 in [0, 3, 0x8000] {
            let events = try records().filter { UInt64($0.offset)! < 1885 }.map { $0.offset == "1796" ? replacing($0, rowFlags: flag) : $0 }
            transactionFailure(flag == 0 ? .sequence : .unsupported) { _ = try assemble(events) }
        }
    }
    func testRotationRequiresMatchingNextFileFDEAndNoOpenGroup() throws {
        let assembler = try TransactionAssembler(file: sourceFile), events = try records()
        for e in events { _ = try assembler.consume(e, file: sourceFile) }
        XCTAssertEqual(assembler.lastCompleteBoundary, BinlogCoordinate(file: "binlog.000004", position: 4))
        _ = try assembler.consume(events[0], file: "binlog.000004")
        try assembler.finish()
        for badFile in [sourceFile, "binlog.000005"] {
            let other = try TransactionAssembler(file: sourceFile)
            for e in events { _ = try other.consume(e, file: sourceFile) }
            transactionFailure(.sequence) { _ = try other.consume(events[0], file: badFile) }
        }
        transactionFailure(.unsupported) { _ = try assemble(synthetic([(4,le(UInt64(99)) + Data("binlog.000004".utf8))])) }
    }
    func testMissingDuplicateAndWrongHeaderCoordinatesCannotAdvance() throws {
        let events = try records()
        for invalid in [Array(events.dropFirst()), [events[0],events[0]], [events[0],events[2]], [replacing(events[0], next: 999)]] {
            transactionFailure(.sequence) { _ = try assemble(invalid) }
        }
        transactionFailure(.incomplete) { try TransactionAssembler(file: sourceFile).finish() }
        let stop = try synthetic([(3,Data()), (33,gtid())])
        transactionFailure(.sequence) { _ = try assemble(stop) }
    }
    func testTransactionResourceLimitsFailWithoutPartialPublication() throws {
        let events = try synthetic([(33,gtid()), (2,query("BEGIN")), (16,le(UInt64(1)))])
        for limits in [TransactionAssembler.Limits(events: 2), .init(wireBytes: 60), .init(retainedBytes: 1500)] {
            let assembler = try TransactionAssembler(file: sourceFile, limits: limits)
            transactionFailure(.limit) {
                for e in events {
                    let group = try assembler.consume(e, file: sourceFile)
                    XCTAssertNil(group)
                }
            }
            XCTAssertEqual(assembler.lastCompleteBoundary?.position, 127)
            transactionFailure(.poisoned) { try assembler.finish() }
        }
    }
    func testTypedQueryStatusAndCViewOwnTheirBytes() throws {
        let status = Data([0,0,0,0,0]), sql = "CREATE TABLE t (id INT)"
        let events = try synthetic([(2,query(sql, error: 1050, status: status))])
        guard case .query(let decoded) = events.last?.control else { return XCTFail("missing typed query") }
        XCTAssertEqual(decoded.sql, Data(sql.utf8)); XCTAssertEqual(decoded.errorCode, 1050)
        XCTAssertEqual(decoded.statusVariables, status)
        var context: OpaquePointer?, result: OpaquePointer?
        XCTAssertEqual(rc_decoder_create(4096, &context), 0)
        let fde = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        _ = fde.withUnsafeBytes { rc_decoder_feed(context, $0.bindMemory(to: UInt8.self).baseAddress, UInt64(fde.count), 4, nil, 0, &result) }
        rc_result_free(result)
        var frame = event(2,query(sql, error: 1050, status: status),at: 127)
        let count = frame.count
        XCTAssertEqual(frame.withUnsafeBytes { rc_decoder_feed(context, $0.bindMemory(to: UInt8.self).baseAddress, UInt64(count), 127, nil, 0, &result) }, 0)
        frame.resetBytes(in: 0..<count); rc_decoder_free(context)
        defer { rc_result_free(result) }
        var info = rc_event(); XCTAssertEqual(rc_result_event(result, &info), 0)
        XCTAssertEqual(info.event_size, UInt32(count)); XCTAssertEqual(info.query_error_code, 1050)
        XCTAssertEqual(Data(bytes: info.query_status.data!, count: Int(info.query_status.length)), status)
    }
    func testMalformedXIDAndGTIDIdentitiesRejectedAtABI() throws {
        for body in [le(UInt64(1)) + Data([0]), Data(repeating: 0, count: 7)] {
            failure(2) { _ = try synthetic([(16, body)]) }
        }
        failure(2) { _ = try synthetic([(33,gtid(0))]) }
        failure(2) { _ = try synthetic([(34,gtid())]) }
    }
    func testUnknownWireRowFlagsSurviveABIForPolicyRejection() throws {
        let input = frames(try Data(contentsOf: directory.appendingPathComponent("Synthetic/typed.binlog")))
        let decoder = try BinlogDecoder()
        _ = try decoder.decode(input[0].1, at: 4)
        _ = try decoder.decode(input[1].1, at: input[1].0, schema: schema("typed").tableMaps[0])
        var row = input[2].1
        row[26] |= 0x80 // Unknown high flag bit, with a freshly valid checksum.
        row = reseal(row)
        let decoded = try decoder.decode(row, at: input[2].0)
        XCTAssertEqual(decoded.rowFlags! & 0x8000, 0x8000)
    }
    func testTableMapCannotBeCommittedWithoutItsRows() throws {
        let original = try records()
        let selected = original.filter { UInt64($0.offset)! < 1796 }
        let assembler = try TransactionAssembler(file: sourceFile)
        for e in selected { _ = try assembler.consume(e, file: sourceFile) }
        let xid = original.first { $0.offset == "1854" }!
        transactionFailure(.sequence) { _ = try assembler.consume(replacing(xid, offset: 1796, next: 1796 + xid.eventSize), file: sourceFile) }
        XCTAssertEqual(assembler.lastCompleteBoundary?.position, 1589)
    }
    func testCancellationAndCallbackFailureDoNotPublishOpenGroup() throws {
        var emitted = 0
        failure(1) {
            try Inspection.inspectTransactions(file: recorded.appendingPathComponent("source-positive.binlog"), sourceFile: sourceFile,
                history: schema("source-positive"), cancelled: { emitted == 5 }) { _ in emitted += 1 }
        }
        XCTAssertEqual(emitted, 5)
        struct CallbackError: Error {}
        emitted = 0
        XCTAssertThrowsError(try Inspection.inspectTransactions(file: recorded.appendingPathComponent("source-positive.binlog"),
            sourceFile: sourceFile, history: schema("source-positive")) { _ in
                emitted += 1; throw CallbackError()
            }) { XCTAssertTrue($0 is CallbackError) }
        XCTAssertEqual(emitted, 1)
    }
    func testCLICompleteGroupsAndTruncatedGroupDiagnostics() throws {
        let cli = (ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"] ?? root.appendingPathComponent(".build/debug").path) + "/mysql-replicator"
        let runner = ProcessRunner(root: root)
        let options = ["--schema", directory.appendingPathComponent("Schema/source-positive.json").path,
            "--transactions", "--binlog-file", sourceFile]
        let success = try runner.run([cli,"inspect",recorded.appendingPathComponent("source-positive.binlog").path] + options)
        XCTAssertTrue(success.stderr.isEmpty); XCTAssertEqual(success.text.split(separator: "\n").count, 9)
        let bytes = try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog"))
        // Keep every schema entry used, then truncate at a frame boundary just
        // before the final XID. Raw event mode succeeds; transaction mode fails.
        try temporary(Data(bytes.prefix(2810))) { file in
            let failed = try runner.run([cli,"inspect",file.path] + options, checked: false)
            XCTAssertNotEqual(failed.status, 0); XCTAssertEqual(failed.text.split(separator: "\n").count, 8)
            let diagnostic = try JSONSerialization.jsonObject(with: failed.stderr) as! [String:Any]
            XCTAssertEqual(diagnostic["error"] as? String, "binlog_transaction_failed")
            XCTAssertEqual(diagnostic["code"] as? String, "incomplete")
            XCTAssertEqual((diagnostic["lastCompleteBoundary"] as? [String:String])?["position"], "2509")
            XCTAssertEqual((diagnostic["transactionStart"] as? [String:String])?["position"], "2509")
        }
        let invalid = try runner.run([cli,"inspect",recorded.appendingPathComponent("source-positive.binlog").path,"--transactions"], checked: false)
        XCTAssertNotEqual(invalid.status, 0); XCTAssertTrue(invalid.stdout.isEmpty)
    }
}
