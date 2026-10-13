import Foundation
import ReplicatorCodec

/// Replay only retained evidence, using saved schema interpretation. No source
/// connection and no dependency on its current schema or retained binlogs.
enum RecoveryRelay {
    struct Intent {
        let group: Int
        let ordinal: Int
        let status: String
        let schemaID: String
        let table: ApplyTable
        let offset: String
        let row: Int
    }
    static func decode(file: URL, groups: inout [Recovery.Group], intents: [Intent], tables: [ApplyTable]) throws {
        let decoder = try BinlogDecoder(maximumEventBytes:16*1024*1024)
        var format: Data?, offset: UInt64 = 4, found: Set<String> = []
        let byEvent = Dictionary(grouping:intents) { "\($0.group):\($0.offset)" }
        var identities: Set<Int> = [], committed: Set<Int> = []
        var decodedRows = Array(repeating:0,count:groups.count)
        let schemas = Dictionary(grouping:tables,by: { $0.identity })
        let end = groups.last!.relayEnd
        try RelayInspection.inspect(file:file,includeRaw:true,endOffset:end) { record in
            guard let raw=record.rawBase64.flatMap({Data(base64Encoded:$0)}), raw.count >= 19 else { throw ApplyError("missing relay event") }
            if record.kind == "formatContext" {
                try decoder.reset(); _ = try decoder.decode(raw,at:4)
                format=raw; offset=4+UInt64(raw.count); return
            }
            guard record.kind == "event" else { return }
            // Table maps establish context. Other earlier groups need not be
            // decoded, and may refer to schemas already retired/pruned.
            let group = groups.firstIndex { record.relayOffset >= $0.relayStart && record.relayEnd <= $0.relayEnd }
            guard raw[4] == 19 || group != nil else { return }
            guard let format else { throw ApplyError("recovery relay lacks format context") }
            var schema: TableSchema?, filtered = false
            if raw[4] == 19 {
                let probe = try BinlogDecoder(maximumEventBytes:16*1024*1024)
                _ = try probe.decode(format,at:4)
                let identity = try probe.decode(raw,at:4+UInt64(format.count),filterTable:true)
                let candidates = schemas[(identity.database ?? "")+"\0"+(identity.table ?? "")] ?? []
                // Relationship/index changes do not change row decoding. Refuse
                // ambiguous column history rather than use today's layout.
                if let table = candidates.first, candidates.allSatisfy({$0.columns == table.columns && $0.primaryKeyColumns == table.primaryKeyColumns}) {
                    schema = TableSchema(offset:offset,eventSHA256:identity.sha256,database:table.database,table:table.table,tableID:identity.tableID!,columns:table.columns.map(\.interpretation))
                } else { filtered = true }
            }
            let event = try decoder.decode(raw,at:offset,schema:schema,filterTable:filtered)
            offset += UInt64(raw.count)
            if let schema, let wire=event.wireColumns, let table=schemas[schema.database+"\0"+schema.table]?.first {
                try DMLTablePlan(table).validate(wire:wire,legacyMetadata:true)
            }
            guard let group else { return }
            if case .gtid(let id) = event.control {
                try require(!identities.contains(group) && groups[group].gtid == id.sid+":"+id.sequence,"relay GTID differs from journal")
                identities.insert(group)
            }
            if case .xid = event.control, record.relayEnd == groups[group].relayEnd {
                try require(String(event.nextPosition) == groups[group].endPosition,"relay COMMIT differs from saved boundary")
                committed.insert(group)
            }
            decodedRows[group] += event.rows.count
            guard !event.rows.isEmpty else { return }
            try require(groups[group].file == record.file && event.nextPosition >= event.eventSize,"row evidence coordinate differs")
            let sourceOffset = String(event.nextPosition-event.eventSize)
            for intent in byEvent["\(group):\(sourceOffset)"] ?? [] {
                let key = "\(group):\(intent.ordinal)"
                try require(!found.contains(key) && intent.row < event.rows.count && event.database == intent.table.database && event.table == intent.table.table,"row evidence does not match intent")
                let row = event.rows[intent.row], plan = try DMLTablePlan(intent.table)
                if let before=row.before { try plan.validate(before) }
                if let after=row.after { try plan.validate(after) }
                groups[group].rows.append(.init(ordinal:intent.ordinal,status:intent.status,schemaID:intent.schemaID,schema:intent.table,sourceEventOffset:intent.offset,sourceRow:intent.row,operation:row.operation,beforeKey:row.before.map { values in intent.table.keyIndexes.map{values[$0]} },afterKey:row.after.map { values in intent.table.keyIndexes.map{values[$0]} },before:row.before,after:row.after))
                found.insert(key)
            }
        }
        try require(identities.count == groups.count && committed.count == groups.count,"pending relay lacks matching committed source transactions")
        try require(found.count == intents.count,"relay does not cover every pending row intent")
        for i in groups.indices {
            try require(decodedRows[i] == groups[i].rows.count,"pending journal does not cover every source row")
            groups[i].rows.sort { $0.ordinal < $1.ordinal }
            groups[i].expectations = try Recovery.fold(groups[i].rows)
            var relationships: [String:ApplyForeignKey] = [:]
            for row in groups[i].rows { for key in row.schema.foreignKeys { relationships[key.identity] = key } }
            groups[i].foreignKeyRelationships = ForeignKeyGraph.sorted(Array(relationships.values))
        }
    }
}
