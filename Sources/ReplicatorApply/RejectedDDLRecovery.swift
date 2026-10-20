import Foundation
import ReplicatorCodec

/// Validate the retained source statement. No target connection or SQL parsing
/// is needed: normal apply must run all compatibility and schema checks again.
enum RejectedDDLRecovery {
    static func decode(file: URL, group: Recovery.Group, failure: TargetFailureDiagnostic) throws
        -> Recovery.RejectedDDL
    {
        let decoder = try BinlogDecoder(maximumEventBytes: BinlogLimits.maximumEventBytes)
        let start = BinlogCoordinate(file: group.file, position: UInt64(group.startPosition)!)
        let assembler = try TransactionAssembler(
            validatedStreamStart: start, allowPreviousGTIDs: false, acceptsExcludedRanges: false)
        var decodeOffset: UInt64 = 4
        var hasFormat = false
        var count = 0
        var completed: CompleteTransaction?
        try RelayInspection.inspect(file: file, includeRaw: true, endOffset: group.relayEnd) { record in
            guard record.kind == "formatContext" || record.kind == "event" else { return }
            guard let raw = record.rawBase64.flatMap({ Data(base64Encoded: $0) }), raw.count >= 19 else {
                throw ApplyError("missing rejected DDL relay bytes")
            }
            if record.kind == "formatContext" {
                try require(count == 0, "format changed inside rejected DDL")
                try decoder.reset()
                let format = try decoder.decode(raw, at: 4)
                try require(format.control == .formatDescription, "invalid rejected DDL format context")
                decodeOffset = 4 + UInt64(raw.count)
                hasFormat = true
                return
            }
            guard record.relayOffset >= group.relayStart else { return }
            let next = (0..<4).reduce(UInt64(0)) { $0 | UInt64(raw[13 + $1]) << (8 * $1) }
            try require(next >= UInt64(raw.count), "invalid rejected DDL event position")
            let position = next - UInt64(raw.count)
            // The relay range can start with idle/rotation events before this GTID.
            if count == 0 && (record.file != group.file || position < start.position) { return }
            try require(
                hasFormat && record.file == group.file && count < 2,
                "rejected DDL is not one source statement")
            let event = try decoder.decode(raw, at: decodeOffset).atSourcePosition(position)
            decodeOffset += UInt64(raw.count)
            let result = try assembler.consume(event, file: group.file)
            count += 1
            if let result {
                try require(
                    record.relayEnd == group.relayEnd && completed == nil,
                    "rejected DDL relay end differs from journal")
                completed = result
            }
        }
        try assembler.finish()
        guard let completed, completed.outcome == .statement, count == 2,
            completed.gtid?.canonical == group.gtid, completed.start == start,
            String(completed.end.position) == group.endPosition,
            case .query(let query) = completed.events.last?.control
        else { throw ApplyError("rejected DDL relay differs from pending journal") }
        let sql = String(decoding: query.sql, as: UTF8.self)
        try require(Data(sql.utf8) == Data((failure.ddlSQL ?? "").utf8), "rejected DDL differs from saved failure")
        if let encoded = failure.ddlContext?.sourceSQLBase64 {
            try require(Data(base64Encoded: encoded) == query.sql, "rejected DDL bytes differ from saved failure")
        }
        return .init(sql: sql, sqlBase64: query.sql.base64EncodedString())
    }
}
