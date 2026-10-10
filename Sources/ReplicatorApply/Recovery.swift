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
    }
    public struct Expectation: Encodable {
        let database: String
        let table: String
        let primaryKeyColumns: [String]
        let key: [DecodedValue]
        let initial: [DecodedValue]?
        var final: [DecodedValue]?
        var ambiguous: Bool
    }
    public struct Group: Encodable {
        let sequence: Int64
        let gtid: String
        let file: String
        let startPosition: String
        let endPosition: String
        let relayStart: UInt64
        let relayEnd: UInt64
        var rows: [Row] = []
        var expectations: [Expectation] = []
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
        let interpretation = "Offline evidence only. Expectations fold exact encoded keys within each transaction; Missing initial/final images mean absent rows. Collation-equivalent keys and later pending transactions can make matches ambiguous. Reconcile the entire pending batch before retry; no target state or commit outcome is inferred. foreignKeyRelationships identifies the connected tables that may require reconciliation; implicit cascade row images are not present in this evidence."
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
        try RecoveryStore(configuration:configuration,writable:false).inspect()
    }
    public static func resolve(configuration: ApplyConfiguration, action: Action, gtids: String, reason: String) throws -> Resolution {
        try RecoveryStore(configuration:configuration,writable:true).resolve(action:action,gtids:gtids,reason:reason)
    }

    static func fold(_ rows: [Row]) throws -> [Expectation] {
        var result: [Expectation] = [], indices: [Data:Int] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func change(_ row: Row, key: [DecodedValue], before: [DecodedValue]?, after: [DecodedValue]?) throws {
            let identity = try encoder.encode([row.schema.database,row.schema.table]) + encoder.encode(key)
            if let index = indices[identity] {
                result[index].ambiguous = result[index].ambiguous || result[index].final != before
                result[index].final = after
            } else {
                indices[identity] = result.count
                result.append(Expectation(database:row.schema.database,table:row.schema.table,primaryKeyColumns:row.schema.primaryKeyColumns,key:key,initial:before,final:after,ambiguous:false))
            }
        }
        for row in rows {
            if let old = row.beforeKey {
                try change(row,key:old,before:row.before,after:row.afterKey == old ? row.after : nil)
            }
            if let new = row.afterKey, new != row.beforeKey { try change(row,key:new,before:nil,after:row.after) }
        }
        return result
    }
}
