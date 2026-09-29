import Foundation

public enum Inspection {
    /// Streaming offline inspection. A failed event emits no record. Earlier
    /// records may already have been emitted; the caller must report failure.
    /// Cancellation happens between bounded frames and discards decoder state.
    public static func inspect(file: URL, history: SchemaHistory? = nil, includeRaw: Bool = false,
                               maximumEventBytes: UInt32 = 4 * 1024 * 1024,
                               cancelled: () -> Bool = { false }, emit: (DecodedEvent) throws -> Void) throws {
        let schemas = try history?.indexed() ?? [:]
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var offset: UInt64 = 0
        func read(_ count: Int, allowEOF: Bool = false) throws -> Data {
            var result = Data()
            while result.count < count {
                let chunk = try input.read(upToCount: count - result.count) ?? Data()
                if chunk.isEmpty {
                    if allowEOF && result.isEmpty { return result }
                    throw DecoderError(code: 2, offset: offset, reason: "truncated offline binlog")
                }
                result.append(chunk)
            }
            return result
        }
        guard try read(4) == Data([0xfe,0x62,0x69,0x6e]) else { throw DecoderError(code: 2, offset: 0, reason: "invalid binlog magic") }
        offset = 4
        let decoder = try BinlogDecoder(maximumEventBytes: maximumEventBytes)
        var seen: Set<UInt64> = []
        var eventCount = 0
        while true {
            if cancelled() { throw DecoderError(code: 1, offset: offset, reason: "inspection cancelled") }
            let header = try read(19, allowEOF: true)
            if header.isEmpty { break }
            let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[9 + $1]) << (8 * $1) }
            guard length >= 23 else { throw DecoderError(code: 2, offset: offset, eventType: header[4], reason: "impossible event length") }
            guard length <= maximumEventBytes else { throw DecoderError(code: 5, offset: offset, eventType: header[4], reason: "event size limit exceeded before allocation") }
            let frame = try header + read(Int(length) - 19)
            let schema = schemas[offset]
            let event = try decoder.decode(frame, at: offset, schema: schema, includeRaw: includeRaw)
            if schema != nil { seen.insert(offset) }
            try emit(event)
            offset += UInt64(length); eventCount += 1
        }
        guard eventCount > 0 else { throw DecoderError(code: 2, offset: offset, reason: "missing format-description event") }
        guard seen.count == schemas.count else { throw DecoderError(code: 7, offset: offset, reason: "schema history has unused table-map positions") }
    }
}
