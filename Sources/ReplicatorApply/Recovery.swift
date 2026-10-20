import Foundation
import ReplicatorCodec

/// Offline DBA evidence. A matching row image is not proof that COMMIT succeeded.
public enum Recovery {
    public enum Action: String { case markApplied = "mark-applied", retry, skip }
    public struct Row: Encodable {
        let ordinal: Int
        let status: String
        let schemaID: String
        let schema: ApplyTable
        let sourceEventOffset: String
        let sourceRow: Int
        let operation: String
        let beforeKey: [DecodedValue]?
        let afterKey: [DecodedValue]?
        let before: [DecodedValue]?
        let after: [DecodedValue]?
        var foreignKeyChecks = true
    }
    public struct Expectation: Encodable {
        let database: String
        let table: String
        let primaryKeyColumns: [String]
        let rowIdentity: RowIdentity?
        let key: [DecodedValue]
        let initial: [DecodedValue]?
        var final: [DecodedValue]?
        var ambiguous: Bool
    }
    public struct RowChange: Encodable {
        let ordinal: Int
        let operation: String
        let database: String
        let table: String
        let schemaID: String
        let before: [DecodedValue]?
        let after: [DecodedValue]?
    }
    public struct RejectedDDL: Encodable {
        let sql: String
        let sqlBase64: String
    }
    public struct Group: Encodable {
        let sequence: Int64
        let gtid: String
        let file: String
        let startPosition: String
        let endPosition: String
        let relayStart: UInt64
        let relayEnd: UInt64
        var rejectedDDL: RejectedDDL? = nil
        var rows: [Row] = []
        var expectations: [Expectation] = []
        // A full-row image is not a unique key. Preserve duplicate operations.
        var fullRowChanges: [RowChange] {
            rows.filter { $0.schema.usesFullRowIdentity }.map {
                .init(
                    ordinal: $0.ordinal, operation: $0.operation, database: $0.schema.database, table: $0.schema.table,
                    schemaID: $0.schemaID, before: $0.before, after: $0.after)
            }
        }
        enum CodingKeys: String, CodingKey {
            case sequence, gtid, file, startPosition, endPosition, relayStart, relayEnd, rows, expectations,
                foreignKeyRelationships, fullRowChanges, rejectedDDL
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sequence, forKey: .sequence)
            try c.encode(gtid, forKey: .gtid)
            try c.encode(file, forKey: .file)
            try c.encode(startPosition, forKey: .startPosition)
            try c.encode(endPosition, forKey: .endPosition)
            try c.encode(relayStart, forKey: .relayStart)
            try c.encode(relayEnd, forKey: .relayEnd)
            try c.encodeIfPresent(rejectedDDL, forKey: .rejectedDDL)
            try c.encode(rows, forKey: .rows)
            try c.encode(expectations, forKey: .expectations)
            try c.encode(foreignKeyRelationships, forKey: .foreignKeyRelationships)
            try c.encode(fullRowChanges, forKey: .fullRowChanges)
        }
        var foreignKeyRelationships: [ApplyForeignKey] = []
    }
    public struct Audit: Encodable {
        let id: String
        let action: String
        let gtids: String
        let reason: String
        let createdAt: String
    }
    public struct Report: Encodable {
        public let kind = "recovery_inspection"
        let profile: String
        let compatibility: CompatibilityPolicy
        let lifecycle: String
        let sourceUUID: String
        let targetUUID: String
        let appliedGTIDSet: String
        let appliedFile: String?
        let appliedPosition: String?
        let durableRelayLength: UInt64
        let unjournaledTailBytes: UInt64
        let diagnostic: String?
        let targetFailure: TargetFailureDiagnostic?
        var pending: [Group]
        let audit: [Audit]
        let interpretation =
            "Offline evidence only. Row images and expectations retain source JSON types. Apply the recorded compatibility rules when comparing with the target. rowIdentity names the lookup index and its ordered columns, or fullRow with all base columns and no index. fullRowChanges retains each keyless operation in order, including duplicates; these images do not identify individual copies or prove the total row count. Keyless rows are not folded into expectations; primaryKeyColumns remains the declared primary key. Expectations fold exact encoded keys within each transaction; Missing initial/final images mean absent rows. Collation-equivalent keys and later pending transactions can make matches ambiguous. Reconcile the entire pending batch before retry; no target state or commit outcome is inferred. foreignKeyRelationships identifies the connected tables that may require reconciliation; implicit cascade row images are not present in this evidence."
    }
    public struct Resolution: Encodable {
        public let kind = "recovery_resolution"
        let auditID: String
        let action: String
        let gtids: String
        let lifecycle: String
        let resumeGTIDSet: String
    }
    public static func inspect(configuration: ApplyConfiguration) throws -> Report {
        try RecoveryStore(configuration: configuration, writable: false).inspect()
    }
    public static func resolve(configuration: ApplyConfiguration, action: Action, gtids: String, reason: String) throws
        -> Resolution
    {
        try RecoveryStore(configuration: configuration, writable: true).resolve(
            action: action, gtids: gtids, reason: reason)
    }

    static func fold(_ rows: [Row]) throws -> [Expectation] {
        var result: [Expectation] = []
        var indices: [Data: Int] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func change(_ row: Row, key: [DecodedValue], before: [DecodedValue]?, after: [DecodedValue]?) throws {
            let identity =
                try encoder.encode([row.schema.database, row.schema.table]) + encoder.encode(row.schema.rowIdentity)
                + encoder.encode(key)
            if let index = indices[identity] {
                result[index].ambiguous = result[index].ambiguous || result[index].final != before
                result[index].final = after
            } else {
                indices[identity] = result.count
                result.append(
                    Expectation(
                        database: row.schema.database, table: row.schema.table,
                        primaryKeyColumns: row.schema.primaryKeyColumns, rowIdentity: row.schema.rowIdentity, key: key,
                        initial: before, final: after, ambiguous: false))
            }
        }
        for row in rows where !row.schema.usesFullRowIdentity {
            if let old = row.beforeKey {
                try change(row, key: old, before: row.before, after: row.afterKey == old ? row.after : nil)
            }
            if let new = row.afterKey, new != row.beforeKey { try change(row, key: new, before: nil, after: row.after) }
        }
        return result
    }
}
