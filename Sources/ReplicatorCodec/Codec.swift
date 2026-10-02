import Foundation
import CReplicatorCodec

public enum Codec {
    public static var abiVersion: UInt32 { replicator_codec_abi_version() }
    public static var capabilities: UInt64 { replicator_codec_capabilities() }
}

public struct DecoderError: Error, CustomStringConvertible {
    public let code: Int32
    public let offset: UInt64
    public let eventType: UInt8?
    public let reason: String
    public var description: String { "decode error \(code) at offset \(offset), event \(eventType.map(String.init) ?? "unknown"): \(reason)" }
    public init(code: Int32, offset: UInt64, eventType: UInt8? = nil, reason: String) {
        self.code = code; self.offset = offset; self.eventType = eventType; self.reason = reason
    }
}
public enum ColumnInterpretation: String, Codable {
    case signed, unsigned, utf8, binary
    var abi: UInt32 { switch self { case .signed: return 2; case .unsigned: return 3; case .utf8: return 4; case .binary: return 5 } }
}
public struct TableSchema: Codable {
    public let offset: UInt64
    public let eventSHA256: String
    public let database: String
    public let table: String
    public let tableID: String
    public let columns: [ColumnInterpretation]
    public init(offset: UInt64, eventSHA256: String, database: String, table: String, tableID: String, columns: [ColumnInterpretation]) {
        self.offset = offset; self.eventSHA256 = eventSHA256; self.database = database; self.table = table; self.tableID = tableID; self.columns = columns
    }
}
public struct SchemaHistory: Codable {
    public let version: Int
    public let tableMaps: [TableSchema]
    public init(version: Int = 1, tableMaps: [TableSchema]) { self.version = version; self.tableMaps = tableMaps }
    public func indexed() throws -> [UInt64: TableSchema] {
        guard version == 1, tableMaps.count <= 10_000 else { throw DecoderError(code: 1, offset: 0, reason: "unsupported schema history version or size") }
        var index: [UInt64: TableSchema] = [:]
        for entry in tableMaps {
            guard entry.offset >= 4, !entry.columns.isEmpty, entry.columns.count <= 256,
                  UInt64(entry.tableID) != nil, entry.eventSHA256.count == 64,
                  entry.eventSHA256.allSatisfy({ "0123456789abcdef".contains($0) }), index[entry.offset] == nil else {
                throw DecoderError(code: 1, offset: entry.offset, reason: "invalid or duplicate schema entry")
            }
            index[entry.offset] = entry
        }
        return index
    }
}

public enum DecodedValue: Equatable, Encodable {
    case absent, null, signed(Int64), unsigned(UInt64), text(String), binary(Data)
    private enum Keys: String, CodingKey { case kind, value }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .absent: try container.encode("absent", forKey: .kind)
        case .null: try container.encode("null", forKey: .kind)
        case .signed(let value): try container.encode("signed", forKey: .kind); try container.encode(String(value), forKey: .value)
        case .unsigned(let value): try container.encode("unsigned", forKey: .kind); try container.encode(String(value), forKey: .value)
        case .text(let value): try container.encode("utf8", forKey: .kind); try container.encode(value, forKey: .value)
        case .binary(let value): try container.encode("binary", forKey: .kind); try container.encode(value.base64EncodedString(), forKey: .value)
        }
    }
}
public struct DecodedRow: Equatable, Encodable {
    public let operation: String
    public let before: [DecodedValue]?
    public let after: [DecodedValue]?
}
public struct WireColumn: Codable, Equatable {
    public let interpretation: ColumnInterpretation?
    public let type: UInt32
    public let maximumBytes: UInt32
    public let nullable: Bool
    public let collation: UInt32
    public let primaryKey: Bool
    public let name: String?
}
public struct DecodedEvent: Equatable, Encodable {
    public let schemaVersion = 3
    public let offset: String
    public let eventSize: UInt32
    public let control: BinlogControl?
    public let rowFlags: UInt32?
    public var wireColumns: [WireColumn]? = nil
    public var replicationFiltered = false
    public let eventType: UInt32
    public let eventName: String
    public let timestamp: UInt32
    public let serverID: UInt32
    public let nextPosition: UInt32
    public let flags: UInt32
    public let sha256: String
    public let tableID: String?
    public let database: String?
    public let table: String?
    public let number: String?
    public let detailBase64: String?
    public let detailText: String?
    public let rows: [DecodedRow]
    public let rawBase64: String?

    /// Live transport validates source coordinates separately from the codec's
    /// contiguous input-stream offsets (GTID filtering may omit source ranges).
    /// Changes only the observation coordinate, never event bytes or headers.
    public func atSourcePosition(_ position: UInt64) -> DecodedEvent {
        var result = DecodedEvent(offset: String(position), eventSize: eventSize, control: control, rowFlags: rowFlags,
            eventType: eventType, eventName: eventName, timestamp: timestamp, serverID: serverID,
            nextPosition: nextPosition, flags: flags, sha256: sha256, tableID: tableID, database: database,
            table: table, number: number, detailBase64: detailBase64, detailText: detailText, rows: rows, rawBase64: rawBase64)
        result.wireColumns = wireColumns
        result.replicationFiltered = replicationFiltered
        return result
    }
}

/// Serialized caller interface. All C views are copied before the Rust result
/// is released; returned Swift values outlive both result and decoder handles.
/// No network, target writes or apply/checkpoint state is involved.
public final class BinlogDecoder {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var failed = false
    public let maximumEventBytes: UInt32
    public init(maximumEventBytes: UInt32 = 4 * 1024 * 1024) throws {
        self.maximumEventBytes = maximumEventBytes
        guard Codec.abiVersion == 4, Codec.capabilities & 1 == 1 else { throw DecoderError(code: 1, offset: 0, reason: "incompatible codec ABI") }
        let status = rc_decoder_create(maximumEventBytes, &context)
        guard status == 0, context != nil else { throw DecoderError(code: status, offset: 0, reason: "cannot create decoder") }
    }
    deinit { rc_decoder_free(context) }
    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        let status = rc_decoder_reset(context)
        guard status == 0 else { throw DecoderError(code: status, offset: 0, reason: "cannot reset decoder") }
        failed = false
    }
    private func bytes(_ view: rc_bytes) -> Data {
        guard view.length != 0, let data = view.data else { return Data() }
        return Data(bytes: data, count: Int(view.length))
    }
    public func decode(_ frame: Data, at offset: UInt64, schema: TableSchema? = nil, includeRaw: Bool = false, filterTable: Bool = false) throws -> DecodedEvent {
        lock.lock(); defer { lock.unlock() }
        let type = frame.count > 4 ? frame[frame.startIndex + 4] : nil
        if failed { throw DecoderError(code: 6, offset: offset, eventType: type, reason: "decoder is poisoned; reset and replay from FDE") }
        do {
            if let schema, schema.offset != offset || type != 19 { throw DecoderError(code: 7, offset: offset, eventType: type, reason: "schema entry does not identify this table map") }
            let kinds = schema?.columns.map(\.abi) ?? []
            var result: OpaquePointer?
            let status = frame.withUnsafeBytes { raw in
                kinds.withUnsafeBufferPointer { columns in
                    rc_decoder_feed_filtered(context, raw.bindMemory(to: UInt8.self).baseAddress, UInt64(raw.count), offset, columns.baseAddress, UInt32(columns.count), filterTable ? 1 : 0, &result)
                }
            }
            defer { rc_result_free(result) }
            var info = rc_event()
            guard let result, rc_result_event(result, &info) == 0 else { throw DecoderError(code: status, offset: offset, eventType: type, reason: "codec returned no result") }
            guard status == 0 else { throw DecoderError(code: status, offset: offset, eventType: type, reason: String(decoding: bytes(info.error), as: UTF8.self)) }
            func identifier(_ data: rc_bytes) throws -> String? {
                let raw = bytes(data)
                if raw.isEmpty { return nil }
                guard let text = String(data: raw, encoding: .utf8) else { throw DecoderError(code: 4, offset: offset, eventType: type, reason: "non-UTF8 database/table identifier unsupported") }
                return text
            }
            let database = try identifier(info.database), table = try identifier(info.table)
            let digest = bytes(info.fingerprint).map { String(format: "%02x", $0) }.joined()
            if let schema {
                guard schema.eventSHA256 == digest, schema.tableID == String(info.table_id), schema.database == database, schema.table == table else {
                    throw DecoderError(code: 7, offset: offset, eventType: type, reason: "schema history fingerprint or table identity differs")
                }
            }
            func image(_ row: UInt32, _ side: UInt32) throws -> [DecodedValue] {
                try (0..<info.column_count).map { column in
                    var value = rc_value()
                    guard rc_result_value(result, row, side, column, &value) == 0 else { throw DecoderError(code: 8, offset: offset, reason: "invalid result index") }
                    switch value.kind {
                    case 0: return .absent
                    case 1: return .null
                    case 2: return .signed(value.signed_value)
                    case 3: return .unsigned(value.unsigned_value)
                    case 4:
                        guard let text = String(data: bytes(value.bytes), encoding: .utf8) else { throw DecoderError(code: 8, offset: offset, reason: "codec emitted invalid UTF8") }
                        return .text(text)
                    case 5: return .binary(bytes(value.bytes))
                    default: throw DecoderError(code: 8, offset: offset, reason: "unknown ABI value kind")
                    }
                }
            }
            let insert = [23, 30].contains(info.event_type), delete = [25, 32].contains(info.event_type)
            let rows = try (0..<info.row_count).map { row in
                DecodedRow(operation: insert ? "insert" : delete ? "delete" : "update", before: insert ? nil : try image(row, 0), after: delete ? nil : try image(row, 1))
            }
            let detail = bytes(info.detail)
            let control: BinlogControl?
            switch info.event_type {
            case 2: control = .query(QueryControl(database: database, sql: detail,
                errorCode: info.query_error_code, statusVariables: bytes(info.query_status)))
            case 3: control = .stop
            case 4:
                guard let file = String(data: detail, encoding: .utf8), !file.isEmpty,
                      !file.utf8.contains(0), info.number >= 4 else {
                    throw DecoderError(code: 2, offset: offset, eventType: type, reason: "invalid rotation coordinate")
                }
                control = .rotate(BinlogCoordinate(file: file, position: info.number))
            case 15: control = .formatDescription
            case 16: control = .xid(String(info.number))
            case 33:
                guard detail.count == 16 else { throw DecoderError(code: 8, offset: offset, reason: "invalid GTID SID from codec") }
                let hex = detail.map { String(format: "%02x", $0) }
                let sid = [0..<4, 4..<6, 6..<8, 8..<10, 10..<16].map { hex[$0].joined() }.joined(separator: "-")
                control = .gtid(SourceGTID(sid: sid, sequence: String(info.number), flags: info.payload_flags))
            case 34: control = .anonymousGTID(flags: info.payload_flags)
            case 35: control = .previousGTIDs
            default: control = nil
            }
            var decoded = DecodedEvent(offset: String(offset), eventSize: info.event_size, control: control,
                rowFlags: [23,24,25,30,31,32].contains(info.event_type) ? info.payload_flags : nil, eventType: info.event_type, eventName: String(decoding: bytes(info.name), as: UTF8.self), timestamp: info.timestamp, serverID: info.server_id, nextPosition: info.next_position, flags: info.flags, sha256: digest,
                tableID: info.column_count == 0 ? nil : String(info.table_id), database: database, table: table,
                number: [4,16,33].contains(info.event_type) ? String(info.number) : nil,
                detailBase64: detail.isEmpty ? nil : detail.base64EncodedString(), detailText: [2,4,15].contains(info.event_type) ? String(data: detail, encoding: .utf8) : nil,
                rows: rows, rawBase64: includeRaw ? bytes(info.raw).base64EncodedString() : nil)
            decoded.replicationFiltered = rc_result_is_filtered(result) == 1
            if info.event_type == 19 && !decoded.replicationFiltered {
                decoded.wireColumns = try (0..<info.column_count).map { index in
                    var c = rc_column()
                    guard rc_result_column(result,index,&c)==0 else {throw DecoderError(code:8,offset:offset,reason:"missing table-map column")}
                    let kind: ColumnInterpretation? = [2:.signed,3:.unsigned,4:.utf8,5:.binary][c.kind]
                    return WireColumn(interpretation:kind,type:c.column_type,maximumBytes:c.maximum_bytes,nullable:c.nullable != 0,
                        collation:c.collation,primaryKey:c.primary_key != 0,name:try identifier(c.name))
                }
            }
            return decoded
        } catch { failed = true; throw error }
    }
}

public extension DecodedEvent {
    /// Conservative retained-data accounting, not a measurement of process RSS.
    var retainedByteCost: Int {
        // Accounting budget, not an RSS claim. Count owned strings, raw/base64
        // copies, query bytes and decoded cells; bound accumulation across events.
        var cost = 1024
        for s in [self.offset, self.eventName, self.sha256, self.tableID, self.database,
                  self.table, self.number, self.detailBase64, self.detailText, self.rawBase64] {
            cost += s?.utf8.count ?? 0
        }
        if case .query(let query) = self.control { cost += query.sql.count + query.statusVariables.count }
        for row in self.rows {
            cost += 128
            for image in [row.before, row.after] {
                for value in image ?? [] {
                    cost += 64
                    switch value {
                    case .text(let s): cost += s.utf8.count
                    case .binary(let d): cost += d.count
                    default: break
                    }
                }
            }
        }
        cost += (wireColumns?.count ?? 0) * 256
        return cost
    }
}
