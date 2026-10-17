import Foundation

/// A complete, already-decoded source DML group, ready for BINLOG transport.
/// This type checks transport framing. The codec and schema planner must still
/// validate row values and target compatibility before construction.
///
/// Keep all row statements in one request. A BINLOG request closes MySQL's
/// table-map context even if the last row event has no STMT_END_F flag.
struct BinlogEventProgram {
    static let formatVersion = 1
    let format: Request
    let rows: Request

    struct Request {
        let events: [Data]
        let commandBytes: Int

        fileprivate init(events: [Data], maximumPacketBytes: Int) throws {
            let rawBytes = events.reduce(0) { $0 + $1.count }
            // COM_QUERY byte + "BINLOG '" + base64 + "'". No client delimiter.
            commandBytes = 10 + ((rawBytes + 2) / 3) * 4
            try require(
                commandBytes <= maximumPacketBytes,
                "BINLOG request needs \(commandBytes) bytes; target packet limit is \(maximumPacketBytes). "
                    + "A source row group cannot be split across requests")
            self.events = events
        }

        func sql() -> String {
            var bytes = Data()
            bytes.reserveCapacity(events.reduce(0) { $0 + $1.count })
            for event in events { bytes.append(event) }
            return "BINLOG '" + bytes.base64EncodedString() + "'"
        }
    }

    init(
        format: Data, events: [Data], maximumPacketBytes: Int, maximumRawBytes: Int,
        transactionalTarget: Bool, preserveSourceGTIDs: Bool
    ) throws {
        // Bound allocations before CRC calculation and base64 expansion. The
        // protocol limit also keeps size arithmetic within Int on all targets.
        try require(
            (1...1_073_741_824).contains(maximumPacketBytes)
                && (1...1_073_741_824).contains(maximumRawBytes), "invalid BINLOG size limits")
        var remaining = maximumRawBytes
        for event in [format] + events {
            try require(event.count <= remaining, "BINLOG group exceeds raw-event byte limit")
            remaining -= event.count
        }
        try Self.validateFrame(format)
        try require(
            Self.byte(format, 4) == 15 && format.count >= 113,
            "BINLOG transport requires a format-description event")
        try require(
            Self.little(format, 19, 2) == 4 && Self.byte(format, 75) == 19,
            "BINLOG transport requires version 4 events with 19-byte headers")
        try require(
            Self.byte(format, format.count - 5) == 1,
            "BINLOG transport requires CRC32 events")
        for (kind, length) in [(19, 8), (30, 10), (31, 10), (32, 10)] {
            try require(
                Self.byte(format, 76 + kind - 1) == length,
                "unsupported BINLOG post-header for event type \(kind)")
        }
        try require(!events.isEmpty, "empty BINLOG row group")
        var tables = Set<UInt64>()
        var statementOpen = false
        var rowEventCount = 0
        var statementCount = 0
        for event in events {
            try Self.validateFrame(event)
            let kind = Self.byte(event, 4)
            try require(
                [19, 30, 31, 32].contains(kind),
                "event type \(kind) is not supported in a prepared BINLOG row group")
            try require(event.count >= 31, "truncated BINLOG table ID or row header")
            let tableID = Self.little(event, 19, 6)
            if kind == 19 {
                try require(
                    tables.insert(tableID).inserted,
                    "duplicate BINLOG table map within a source statement")
                statementOpen = true
                continue
            }
            try require(tables.contains(tableID), "BINLOG row event has no table map in its source statement")
            try Self.validateFullImageHeader(event, update: kind == 31)
            rowEventCount += 1
            if Self.little(event, 25, 2) & 1 != 0 {
                statementCount += 1
                tables.removeAll(keepingCapacity: true)
                statementOpen = false
            }
        }
        try require(
            rowEventCount > 0 && !statementOpen,
            "BINLOG group ends before a row event with STMT_END_F")
        try require(
            transactionalTarget || !preserveSourceGTIDs || statementCount == 1,
            "BINLOG cannot preserve one source GTID across multiple MyISAM row statements; "
                + "the target completes the GTID at the first statement end")
        self.format = try Request(events: [format], maximumPacketBytes: maximumPacketBytes)
        rows = try Request(events: events, maximumPacketBytes: maximumPacketBytes)
    }

    private static func validateFullImageHeader(_ event: Data, update: Bool) throws {
        let end = event.count - 4
        try require(end >= 29, "truncated BINLOG row extra header")
        let extra = Int(little(event, 27, 2))
        var cursor = 27 + extra
        try require(extra >= 2 && cursor < end, "invalid BINLOG row extra-header length")
        let first = byte(event, cursor)
        cursor += 1
        let columns: Int
        if first < 251 {
            columns = first
        } else {
            let length = first == 252 ? 2 : first == 253 ? 3 : first == 254 ? 8 : 0
            try require(length > 0 && cursor + length <= end, "invalid BINLOG column count")
            let value = little(event, cursor, length)
            try require(value <= 4096, "invalid BINLOG column count")
            columns = Int(value)
            cursor += length
        }
        try require((1...4096).contains(columns), "invalid BINLOG column count")
        let bitmapBytes = (columns + 7) / 8
        try require(cursor + bitmapBytes * (update ? 2 : 1) < end, "truncated BINLOG row image")
        for _ in 0..<(update ? 2 : 1) {
            for column in 0..<columns {
                try require(
                    byte(event, cursor + column / 8) & (1 << (column % 8)) != 0,
                    "BINLOG transport requires FULL row images")
            }
            cursor += bitmapBytes
        }
    }

    private static func validateFrame(_ event: Data) throws {
        try require(event.count >= 23, "truncated BINLOG event")
        try require(little(event, 9, 4) == UInt64(event.count), "BINLOG event length differs from its header")
        var crc: UInt32 = 0xffff_ffff
        for (offset, value) in event.dropLast(4).enumerated() {
            // The source can change this flag after writing the FDE checksum.
            let byte = offset == 17 && Self.byte(event, 4) == 15 ? value & ~1 : value
            crc = crc >> 8 ^ crcTable[Int((crc ^ UInt32(byte)) & 255)]
        }
        try require(
            UInt64(crc ^ 0xffff_ffff) == little(event, event.count - 4, 4),
            "BINLOG event CRC32 mismatch")
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        return crc
    }
    private static func byte(_ data: Data, _ offset: Int) -> Int { Int(data[data.startIndex + offset]) }
    private static func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(byte(data, offset + $1)) << (8 * $1) }
    }
}

/// Owned by one target connection. Never carry this cache across reconnects.
struct BinlogFormatContext {
    private var format: Data?
    init() {}
    mutating func install(_ request: BinlogEventProgram.Request, send: (String) throws -> Void) throws {
        guard format != request.events[0] else { return }
        try send(request.sql())
        // FDE changes internal GTID state, even when preservation is disabled.
        try send("SET SESSION GTID_NEXT='AUTOMATIC'")
        format = request.events[0]
    }
}
