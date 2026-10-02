import Foundation
import ReplicatorCodec

public struct LiveRecord: Encodable {
    public let schemaVersion = 1
    public let kind: String
    public let file: String
    public let observedPosition: String
    public let event: DecodedEvent?
    public let rawBase64: String?
}

/// Turns dump-protocol envelopes into independently checked source coordinates.
/// Decoder input offsets remain contiguous over the bytes actually delivered;
/// source offsets are retained separately and restored on decoded observations.
final class StreamProcessor {
    let timings: StageTimings
    let config: CaptureConfiguration
    let excluded: GTIDSet
    var completeGTIDs: GTIDSet
    let includeRaw: Bool
    let allowDDL: Bool
    let ignoreTable: ((String, String) -> Bool)?
    var decoder: BinlogDecoder?
    var format: Data?
    var decoderOffset: UInt64 = 4
    var cursor: BinlogCoordinate?
    var announced: BinlogCoordinate?
    var rotatedTo: BinlogCoordinate?
    var assembler: TransactionAssembler?
    var transactionCount = 0
    var eventCount = 0
    var heartbeatCount = 0
    var announcementCount = 0
    var receivedBytes: UInt64 = 0
    var firstGroup = true
    let resolveSchema: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])?
    let emitEvent: (LiveRecord) throws -> Void
    let emitTransaction: (CompleteTransaction) throws -> Void

    init(config: CaptureConfiguration, includeRaw: Bool,
         emitEvent: @escaping (LiveRecord) throws -> Void,
         emitTransaction: @escaping (CompleteTransaction) throws -> Void,
         resolveSchema: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])? = nil,
         timings: StageTimings = .init(), allowDDL: Bool = false, ignoreTable: ((String, String) -> Bool)? = nil) throws {
        self.timings = timings
        self.ignoreTable = ignoreTable
        self.allowDDL=allowDDL
        self.resolveSchema = resolveSchema
        self.config = config; self.includeRaw = includeRaw
        self.excluded = try GTIDSet(config.start.executedGTIDs)
        self.completeGTIDs = self.excluded
        self.emitEvent = emitEvent; self.emitTransaction = emitTransaction
    }
    var lastCompleteBoundary: BinlogCoordinate? { assembler?.lastCompleteBoundary }
    var pendingTransactionStart: BinlogCoordinate? { assembler?.pendingTransactionStart }
    func read<T: FixedWidthInteger>(_ data: Data, _ at: Int, _: T.Type) -> T {
        (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(data[at + $1]) << (8 * $1) }
    }
    func check(_ condition: Bool, _ reason: String) throws { if !condition { throw CaptureError(reason) } }
    // Pseudo-event CRC only. Physical events and FDE use the Rust codec's CRC.
    func validatePseudo(_ data: Data) throws {
        try check(data.count <= 4096, "oversized transport pseudo-event")
        var crc: UInt32 = 0xffffffff
        for byte in data.dropLast(4) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        try check(crc ^ 0xffffffff == read(data, data.count-4, UInt32.self), "transport pseudo-event CRC mismatch")
    }
    func filename(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= 255, !data.contains(0), let result = String(data: data, encoding: .utf8) else {
            throw CaptureError("invalid source binlog filename")
        }
        return result
    }
    func atOrAfterBootstrap(_ at: BinlogCoordinate) -> Bool {
        guard let initialFile = config.start.file, let initialPosition = config.start.position else {
            // GTID-only starts rely on the caller's externally established set
            // and matching historical schema. No synthetic position is invented.
            return config.mode == "gtid"
        }
        if at.file == initialFile { return at.position >= initialPosition }
        func parts(_ name: String) -> (String, UInt64)? {
            guard let dot = name.lastIndex(of: "."), let n = UInt64(name[name.index(after: dot)...]) else { return nil }
            return (String(name[..<dot]), n)
        }
        guard let a = parts(at.file), let b = parts(initialFile) else { return false }
        return a.0 == b.0 && a.1 > b.1
    }
    func consume(_ frame: Data) throws {
        try check(frame.count >= 23 && frame.count <= Int(config.maximumEventBytes ?? 4*1024*1024), "live event size limit or short header")
        try check(Int(read(frame, 9, UInt32.self)) == frame.count, "live frame/header length mismatch")
        receivedBytes += UInt64(frame.count)
        let type = frame[4], next = read(frame, 13, UInt32.self), flags = read(frame, 17, UInt16.self)
        if type == 4 && flags & 0x20 != 0 {
            try check(frame.count >= 31 && next == 0 && read(frame, 0, UInt32.self) == 0 && flags == 0x20,
                      "invalid artificial rotation")
            try validatePseudo(frame)
            let target = BinlogCoordinate(file: try filename(Data(frame[27..<frame.count-4])), position: read(frame, 19, UInt64.self))
            try check(target.position >= 4 && announced == nil, "duplicate/invalid rotation announcement")
            if let expected = rotatedTo {
                try check(target == expected, "rotation announcement disagrees with physical rotation")
            } else {
                try check(cursor == nil && assembler == nil, "unexpected rotation announcement")
                if config.mode == "file-position" {
                    try check(target == BinlogCoordinate(file: config.start.file!, position: UInt64(config.start.position!)), "source changed requested positional start")
                } else { try check(target.position == 4, "GTID file announcement must begin at position 4") }
            }
            announced = target; announcementCount += 1
            try emitEvent(LiveRecord(kind: "rotationAnnouncement", file: target.file, observedPosition: String(target.position), event: nil, rawBase64: includeRaw ? frame.base64EncodedString() : nil))
            return
        }
        if type == 15 {
            guard let start = announced else { throw CaptureError("format event without rotation announcement") }
            let fresh = try BinlogDecoder(maximumEventBytes: config.maximumEventBytes ?? 4*1024*1024, timings:config.decoderProfiling == true ? timings : nil)
            let event = try measureDecode("decode.call.format") { try fresh.decode(frame, at: 4, includeRaw: includeRaw) }
            let fullFile = start.position == 4
            try check(fullFile ? UInt64(next) == UInt64(frame.count)+4 : next == 0, "unexpected dump format-event position")
            let begin = BinlogCoordinate(file: start.file, position: fullFile ? UInt64(next) : start.position)
            assembler = try TransactionAssembler(validatedStreamStart: begin, allowPreviousGTIDs: fullFile,
                acceptsExcludedRanges: config.mode == "gtid" && !excluded.isEmpty)
            decoder = fresh; format = frame; decoderOffset = UInt64(frame.count) + 4
            cursor = begin; announced = nil; rotatedTo = nil
            try emitEvent(LiveRecord(kind: "formatContext", file: start.file, observedPosition: String(begin.position), event: event, rawBase64: nil))
            return
        }
        guard let current = cursor, let decoder, let assembler, announced == nil, rotatedTo == nil else {
            throw CaptureError("source event before a validated format context")
        }
        if type == 27 {
            try validatePseudo(frame)
            try check(flags == 0 && read(frame, 0, UInt32.self) == 0 && (try filename(Data(frame[19..<frame.count-4]))) == current.file,
                      "invalid heartbeat identity/header")
            let observed = BinlogCoordinate(file: current.file, position: UInt64(next))
            if observed.position != current.position {
                try check(config.mode == "gtid" && !excluded.isEmpty && observed.position > current.position,
                          "unexpected heartbeat position gap")
                try assembler.advanceExcludedRange(to: observed)
                cursor = observed
            }
            heartbeatCount += 1
            try emitEvent(LiveRecord(kind: "heartbeat", file: current.file, observedPosition: String(next), event: nil, rawBase64: includeRaw ? frame.base64EncodedString() : nil))
            return
        }
        try check(flags & 0x20 == 0 && UInt64(next) >= UInt64(frame.count), "unexpected artificial event/zero source position")
        let offset = UInt64(next) - UInt64(frame.count)
        try check(offset == current.position, "source event gap without a GTID exclusion heartbeat")
        var schema: TableSchema?
        var filterTable = false
        if type == 19 {
            // Probe with the same codec, then bind discovered wire/target metadata
            // (or explicit legacy debug history). Never query the source's
            // current information_schema to interpret historical events.
            let probe = try BinlogDecoder(maximumEventBytes: config.maximumEventBytes ?? 4*1024*1024, timings:config.decoderProfiling == true ? timings : nil)
            _ = try measureDecode("decode.call.probe_format") { try probe.decode(format!, at: 4) }
            // Identity probe accepts column types outside the applier subset.
            // Included maps are decoded again with the normal strict checks.
            var identity = try measureDecode("decode.call.probe_identity") { try probe.decode(frame, at: UInt64(format!.count)+4, filterTable: true) }
            guard let db = identity.database, let name = identity.table, let id = identity.tableID else {throw CaptureError("missing table identity")}
            filterTable = ignoreTable?(db, name) ?? false
            if !filterTable {
            try probe.reset()
            _ = try measureDecode("decode.call.probe_format") { try probe.decode(format!, at: 4) }
            identity = try measureDecode("decode.call.probe_metadata") { try probe.decode(frame, at: UInt64(format!.count)+4) }
            let columns: [ColumnInterpretation]
            if config.version == 2 {
                if let resolveSchema { columns = try resolveSchema(identity.atSourcePosition(offset),current) }
                else {
                    guard let wire = identity.wireColumns else {throw CaptureError("missing wire schema")}
                    columns = try wire.map { c in
                        guard let kind = c.interpretation else {throw CaptureError("missing/unsupported wire signedness or charset")}
                        return kind
                    }
                }
            } else {
                guard let table = (config.tables ?? []).first(where:{$0.database==db && $0.table==name}) else {throw CaptureError("table map outside supplied historical schema")}
                columns = table.columns
            }
            schema = TableSchema(offset:decoderOffset,eventSHA256:identity.sha256,database:db,table:name,tableID:id,columns:columns)
            }
        }
        let event = try measureDecode("decode.call.event") { try decoder.decode(frame, at: decoderOffset, schema: schema, includeRaw: includeRaw, filterTable: filterTable).atSourcePosition(offset) }
        if case .query(let query) = event.control {
            try check(allowDDL || [Data("BEGIN".utf8), Data("COMMIT".utf8), Data("ROLLBACK".utf8)].contains(query.sql),
                      "live schema window stops at DDL or non-control SQL")
            try check(assembler.pendingTransactionStart != nil, "query without GTID on GTID-ON source")
        }
        if case .gtid(let gtid) = event.control {
            try check(!completeGTIDs.contains(sid: gtid.sid, sequence: gtid.sequence), "source returned an excluded or duplicate GTID")
            if firstGroup {
                try check(atOrAfterBootstrap(current), "first live group precedes schema/bootstrap boundary")
                firstGroup = false
            }
        }
        if case .anonymousGTID = event.control { throw CaptureError("anonymous transaction from GTID-ON source") }
        let complete = try timings.measure("capture.assemble") { try assembler.consume(event, file: current.file) }
        decoderOffset += UInt64(frame.count); cursor = BinlogCoordinate(file: current.file, position: UInt64(next)); eventCount += 1
        try emitEvent(LiveRecord(kind: "event", file: current.file, observedPosition: String(next), event: event, rawBase64: nil))
        if let complete {
            var nextSet = completeGTIDs
            guard let identity = complete.gtid else { throw CaptureError("completed live group has no GTID") }
            try nextSet.include(sid: identity.sid, sequence: identity.sequence)
            try emitTransaction(complete); transactionCount += 1; completeGTIDs = nextSet
        }
        if case .rotate(let destination) = event.control { rotatedTo = destination }
    }
    private func measureDecode<T>(_ role: String, _ body: () throws -> T) rethrows -> T {
        try timings.measure("capture.decode") {
            if config.decoderProfiling == true { return try timings.measure(role,body) }
            return try body()
        }
    }
    func finish() throws {
        try check(announced == nil && assembler != nil, "dump ended before format context")
        try assembler!.finish()
    }
}
