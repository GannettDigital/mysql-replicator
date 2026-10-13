import Foundation
import ReplicatorCodec

enum ProhibitedDDL: Error, CustomStringConvertible {
    case trigger, event
    var description: String {
        switch self {
        case .trigger: return "DDL policy rejects triggers: ordinary target SQL would fire replica-side triggers"
        case .event: return "DDL policy rejects events: scheduled target writes are unsupported"
        }
    }
}

/// External SQL would fire target triggers and enable scheduled events. These
/// policies intentionally offer no unsafe "execute anyway" alternative.
public struct DDLPolicy: Decodable {
    public var triggers: String = "skip"
    public var events: String = "reject"
    public init() {}
    enum CodingKeys: String, CodingKey { case triggers, events }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        triggers = try c.decodeIfPresent(String.self,forKey:.triggers) ?? "skip"
        events = try c.decodeIfPresent(String.self,forKey:.events) ?? "reject"
        try validate()
    }
    func validate() throws {
        try require(["skip","reject"].contains(triggers), "ddlPolicy.triggers must be skip or reject: ordinary target SQL fires triggers")
        try require(events == "reject", "ddlPolicy.events must be reject: scheduled target writes are unsupported")
    }
    func skippedQuery(_ query: QueryControl, profile: ReplicationProfile) throws -> SkippedDDL? {
        // Reject prohibited object classes even when their session metadata is
        // outside the executable DDL subset. The skip policy still validates
        // trigger headers using their recorded SQL mode below.
        do { try Self.rejectProhibited(query) }
        catch ProhibitedDDL.trigger where triggers == "skip" { }
        if let trigger = try skippedTrigger(query) { return trigger }
        guard profile.sourceContract.requiresHistoricalSchema else { return nil }
        let mode = try query.statusVariables.isEmpty ? 0 : QuerySessionContext(query:query).sqlMode
        var parser = try DDLParser(query.sql,database:query.database,sqlMode:mode)
        guard parser.take("DROP"), parser.take("TEMPORARY") else { return nil }
        // 5.7 sql_base.cc::close_temporary_tables and sql_table.cc emit
        // conditional cleanup even for ROW streams. No temporary objects are
        // replayed by this applier, so this cannot affect a permanent table.
        try parser.expect("TABLE"); try parser.expect("IF"); try parser.expect("EXISTS")
        let first = try parser.name()
        while parser.take(",") { _ = try parser.name() }
        try parser.end()
        try require(query.errorCode == 0,"cannot skip failed temporary cleanup")
        return SkippedDDL(name:first,sql:String(decoding:query.sql,as:UTF8.self),reason:"row replication temporary-table cleanup")
    }
    func skippedTrigger(_ query: QueryControl) throws -> SkippedDDL? {
        guard triggers == "skip" else { return nil }
        let mode = try query.statusVariables.isEmpty ? 0 : QuerySessionContext(query:query).sqlMode
        var parser = try DDLParser(query.sql,database:query.database,sqlMode:mode)
        guard let name = try parser.triggerToSkip() else { return nil }
        try require(query.errorCode == 0,"cannot skip failed source trigger DDL")
        return SkippedDDL(name:name,sql:String(decoding:query.sql,as:UTF8.self),reason:"ddlPolicy.triggers=skip")
    }
    /// Rejection does not require executing SQL or accepting its session
    /// metadata. In particular, trigger Query events may carry context outside
    /// the supported execution profile. Other lexer/parser failures are left to
    /// the normal, strict, mode-aware path below.
    static func rejectProhibited(_ query: QueryControl) throws {
        do {
            var parser = try DDLParser(query.sql,database:query.database)
            _ = try parser.objectStatement()
        } catch let policy as ProhibitedDDL { throw policy }
        catch { }
    }
}

struct SkippedDDL {
    let name: TableName
    let sql: String
    let reason: String
}

public struct ApplyPartition: Codable, Equatable {
    public let name: String
    public let method: String
    public let expression: String
    public let description: String?
    func validate() throws {
        _ = try quoted(name)
        try require(["RANGE","RANGE COLUMNS","LIST","LIST COLUMNS","HASH","LINEAR HASH","KEY","LINEAR KEY"].contains(method),"unsupported partition method")
        try require(!expression.isEmpty,"missing partition expression")
    }
}

struct SchemaTransition: Codable {
    let before: ApplyTable?
    let after: ApplyTable?
    var afterAlternatives: [ApplyTable]? = nil
}

enum PartitionChange: Equatable {
    case replace([ApplyPartition])
    case add([ApplyPartition])
    case drop([String])
    case truncate([String])
    case reorganize([String],[ApplyPartition])
    case coalesce(Int)
    case remove
    case exchange(String,TableName)
}

enum AlterAction: Equatable {
    case addForeignKey(ApplyForeignKey,String?)
    case dropForeignKey(String)
    case add(ApplyColumn,ColumnPlacement)
    case modify(String,ApplyColumn,ColumnPlacement?)
    case drop(String)
    case indexes(IndexChange)
    case defaultValue(String,String?)
    case primaryKey([String]?)
    case partition(PartitionChange)
}

struct ObjectDDL: Equatable {
    enum Kind: String { case view = "VIEW", procedure = "PROCEDURE", function = "FUNCTION" }
    enum Operation { case create, replace, alter, drop }
    let kind: Kind
    let operation: Operation
    let name: TableName
    var ifExists = false
}
