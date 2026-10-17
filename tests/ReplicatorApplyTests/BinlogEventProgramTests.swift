import Foundation
import XCTest

@testable import ReplicatorApply

final class BinlogEventProgramTests: XCTestCase {
    private func put(_ value: UInt64, into data: inout Data, at offset: Int, bytes: Int) {
        for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private func checksum(_ event: Data) -> Data {
        var data = event
        var crc: UInt32 = 0xffff_ffff
        for (offset, value) in data.dropLast(4).enumerated() {
            crc ^= UInt32(offset == 17 && data[4] == 15 ? value & ~1 : value)
            for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        put(UInt64(crc ^ 0xffff_ffff), into: &data, at: data.count - 4, bytes: 4)
        return data
    }
    private func frame(_ kind: UInt8, body: Data) -> Data {
        var data = Data(repeating: 0, count: 19)
        data[4] = kind
        data.append(body)
        data.append(Data(repeating: 0, count: 4))
        put(UInt64(data.count), into: &data, at: 9, bytes: 4)
        return checksum(data)
    }
    private func format() -> Data {
        var body = Data(repeating: 0, count: 57 + 38 + 1)
        body[0] = 4
        body[56] = 19
        for (kind, length) in [(19, 8), (30, 10), (31, 10), (32, 10)] { body[57 + kind - 1] = UInt8(length) }
        body[body.count - 1] = 1
        var data = frame(15, body: body)
        data[17] = 1  // Mutable binlog-in-use flag, absent from CRC input.
        return data
    }
    private func map(_ id: UInt64 = 1) -> Data {
        var body = Data(repeating: 0, count: 12)
        put(id, into: &body, at: 0, bytes: 6)
        return frame(19, body: body)
    }
    private func row(_ id: UInt64 = 1, end: Bool = true, kind: UInt8 = 30) -> Data {
        var body = Data(repeating: 0, count: 10)
        put(id, into: &body, at: 0, bytes: 6)
        body[6] = end ? 1 : 0
        body[8] = 2
        body.append(contentsOf: kind == 31 ? [1, 1, 1, 0, 42, 0, 43] : [1, 1, 0, 42])
        return frame(kind, body: body)
    }
    private func program(
        _ events: [Data], format: Data? = nil, packet: Int = 65536, raw: Int = 65536,
        transactional: Bool = true, preserve: Bool = true
    ) throws
        -> BinlogEventProgram
    {
        try BinlogEventProgram(
            format: format ?? self.format(), events: events,
            maximumPacketBytes: packet, maximumRawBytes: raw,
            transactionalTarget: transactional, preserveSourceGTIDs: preserve)
    }
    func testEachCompleteSourceStatementGetsOneRequestWithExactBytes() throws {
        let frames = [map(), row(end: false), row(), map(2), row(2, kind: 31), map(), row(kind: 32)]
        let prepared = try program(frames)
        XCTAssertEqual(
            prepared.statements.map(\.events), [Array(frames[0..<3]), Array(frames[3..<5]), Array(frames[5..<7])])
        for request in prepared.statements {
            let sql = request.sql()
            XCTAssertEqual(request.commandBytes, sql.utf8.count + 1)
            XCTAssertEqual(Data(base64Encoded: String(sql.dropFirst(8).dropLast())), request.events.reduce(Data(), +))
        }
        XCTAssertEqual(prepared.format.sql(), "BINLOG '" + format().base64EncodedString() + "'")
        XCTAssertEqual(BinlogEventProgram.formatVersion, 1)
    }
    func testPacketBudgetIncludesBase64SQLAndCommandByte() throws {
        let frames = [map(), row()]
        let prepared = try program(frames)
        let limit = max(prepared.format.commandBytes, prepared.statements[0].commandBytes)
        XCTAssertNoThrow(try program(frames, packet: limit))
        XCTAssertThrowsError(try program(frames, packet: limit - 1))
        let many = [map()] + Array(repeating: row(end: false), count: 10) + [row()]
        let large = try program(many)
        XCTAssertThrowsError(try program(many, packet: large.statements[0].commandBytes - 1))
    }
    func testPacketLimitAppliesToEachStatementNotTheWholeTransaction() throws {
        let statement = [map()] + Array(repeating: row(end: false), count: 10) + [row()]
        let first = try program(statement)
        let limit = max(first.format.commandBytes, first.statements[0].commandBytes)
        let multiple = try program(statement + statement, packet: limit)
        XCTAssertEqual(multiple.statements.count, 2)
        XCTAssertTrue(multiple.statements.allSatisfy { $0.commandBytes <= limit })
    }
    func testPreservedGTIDResetsBeforeInitialOrChangedFormatButNotCacheHits() throws {
        let first = try program([map(), row()]).format
        var changed = format()
        changed[21] = 56
        let next = try program([map(), row()], format: checksum(changed)).format
        var context = BinlogFormatContext()
        var sent: [String] = []
        try context.install(first, preserveSourceGTIDs: true) { sent.append($0) }
        XCTAssertEqual(sent, ["SET SESSION GTID_NEXT='AUTOMATIC'", first.sql()])
        try context.install(first, preserveSourceGTIDs: true) { _ in XCTFail("cached FDE must not reset GTID") }
        sent = []
        try context.install(next, preserveSourceGTIDs: true) { sent.append($0) }
        XCTAssertEqual(sent, ["SET SESSION GTID_NEXT='AUTOMATIC'", next.sql()])
    }
    func testRawBudgetIncludesFormatAndAllEvents() throws {
        let frames = [map(), row()]
        let size = format().count + frames.reduce(0) { $0 + $1.count }
        XCTAssertNoThrow(try program(frames, raw: size))
        XCTAssertThrowsError(try program(frames, raw: size - 1))
        XCTAssertThrowsError(try program(frames, raw: 0))
        XCTAssertThrowsError(try program(frames, packet: Int.max))
    }
    func testRejectsMissingMapsAndIncompleteStatements() throws {
        for frames in [
            [Data](), [row()], [map()], [map(), row(end: false)],
            [map(), row(2)], [map(), row(), row()], [map(), row(), map()],
        ] {
            XCTAssertThrowsError(try program(frames))
        }
    }
    func testMultipleTablesInOneStatementAndMapReuseAfterEnd() throws {
        XCTAssertNoThrow(try program([map(), map(2), row(end: false), row(2), map(), row()]))
        XCTAssertThrowsError(try program([map(), map(), row()]))
    }
    func testMyISAMSourceGTIDCannotSpanMultipleStatementEnds() throws {
        let statements = [map(), row(), map(), row(kind: 31)]
        XCTAssertThrowsError(try program(statements, transactional: false))
        XCTAssertNoThrow(try program(statements, transactional: true))
        XCTAssertNoThrow(try program(statements, transactional: false, preserve: false))
        XCTAssertNoThrow(try program([map(), row(end: false), row()], transactional: false))
    }
    func testRejectsNonRowEventsRatherThanDroppingThem() throws {
        for kind: UInt8 in [2, 4, 15, 16, 23, 24, 25, 29, 33, 39, 40, 42] {
            XCTAssertThrowsError(try program([map(), frame(kind, body: Data(repeating: 0, count: 12)), row()]))
        }
    }
    func testCRCAndLengthsAreCheckedBeforePreparation() throws {
        var corrupted = row()
        corrupted[corrupted.count - 5] ^= 1
        var badLength = row()
        badLength[9] &+= 1
        for invalid in [Data(), Data(row().prefix(18)), Data(row().dropLast()), corrupted, badLength] {
            XCTAssertThrowsError(try program([map(), invalid]))
        }
        var corruptFormat = format()
        corruptFormat[17] ^= 2
        XCTAssertThrowsError(try program([map(), row()], format: corruptFormat))
    }
    func testRejectsUnsupportedFormatWithoutRewritingIt() throws {
        for (offset, value): (Int, UInt8) in [(19, 3), (75, 20), (76 + 29, 8), (format().count - 5, 0)] {
            var fde = format()
            fde[offset] = value
            XCTAssertThrowsError(try program([map(), row()], format: checksum(fde)))
        }
        XCTAssertThrowsError(try program([map(), row()], format: row()))
    }
    func testRejectsMinimalImagesAndTruncatedExtraHeaders() throws {
        for (offset, value): (Int, UInt8) in [(27, 0), (27, 255), (29, 0), (29, 251), (29, 254), (30, 0)] {
            var event = row()
            event[offset] = value
            XCTAssertThrowsError(try program([map(), checksum(event)]))
        }
        var update = row(kind: 31)
        update[31] = 0  // Before bitmap is FULL, after bitmap is not.
        XCTAssertThrowsError(try program([map(), checksum(update)]))
    }
    func testNewFormatMustBePreparedForEachProgram() throws {
        let first = try program([map(), row()])
        var nextFormat = format()
        nextFormat[21] = 56
        nextFormat = checksum(nextFormat)
        let next = try program([map(), row()], format: nextFormat)
        XCTAssertNotEqual(first.format.sql(), next.format.sql())
        XCTAssertEqual(first.statements.map { $0.sql() }, next.statements.map { $0.sql() })
    }
    func testDataSlicesWithNonzeroIndices() throws {
        let prefixed = Data([0, 0]) + row()
        XCTAssertNoThrow(try program([map(), prefixed.dropFirst(2)]))
    }
    func testFormatCacheResetsOnReconnectAndDoesNotCacheFailedSetup() throws {
        let request = try program([map(), row()]).format
        var context = BinlogFormatContext()
        var sent: [String] = []
        try context.install(request, preserveSourceGTIDs: false) { sent.append($0) }
        try context.install(request, preserveSourceGTIDs: false) { sent.append($0) }
        XCTAssertEqual(sent, [request.sql(), "SET SESSION GTID_NEXT='AUTOMATIC'"])
        context = BinlogFormatContext()
        XCTAssertThrowsError(
            try context.install(request, preserveSourceGTIDs: false) { sql in
                if sql.hasPrefix("SET") { throw ApplyError("reset failed") }
            })
        sent = []
        try context.install(request, preserveSourceGTIDs: false) { sent.append($0) }
        XCTAssertEqual(sent.count, 2)
    }
}
