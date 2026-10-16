import Foundation
import MySQLSyntax
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
    func skippedQuery(_ query: QueryControl, profile: ReplicationProfile,tokens:[DDLToken]? = nil,targetVersion:Int? = nil) throws -> SkippedDDL? {
        // Reject prohibited object classes even when their session metadata is
        // outside the executable DDL subset. The skip policy still validates
        // trigger headers using their recorded SQL mode below.
        let expanded=try LoggedDDL.parsingView(query,targetVersion:targetVersion ?? (profile.targetContract.versionPrefix == "5.7." ? 50700 : 80400))
        do { try Self.rejectProhibited(expanded) }
        catch ProhibitedDDL.trigger where triggers == "skip" { }
        let tokens=try tokens ?? DDLParser(query:expanded).tokens
        if let trigger = try skippedTrigger(query,tokens:tokens) { return trigger }
        guard profile.sourceContract.requiresHistoricalSchema else { return nil }
        var parser = try DDLParser(query:query,tokens:tokens)
        guard parser.take("DROP"), parser.take("TEMPORARY") else { return nil }
        // 5.7 sql_base.cc::close_temporary_tables and sql_table.cc emit
        // conditional cleanup even for ROW streams. No temporary objects are
        // replayed by this applier, so this cannot affect a permanent table.
        try parser.expect("TABLE"); try parser.expect("IF"); try parser.expect("EXISTS")
        let first = try parser.name()
        while parser.take(",") { _ = try parser.name() }
        try parser.end()
        try require(query.errorCode == 0,"cannot skip failed temporary cleanup")
        return SkippedDDL(name:first,sql:String(decoding:query.sql,as:UTF8.self),reason:"row replication temporary-table cleanup",tokens:tokens)
    }
    func skippedTrigger(_ query: QueryControl,tokens:[DDLToken]? = nil) throws -> SkippedDDL? {
        guard triggers == "skip" else { return nil }
        var parser = try DDLParser(query:query,tokens:tokens)
        guard let name = try parser.triggerToSkip() else { return nil }
        try require(query.errorCode == 0,"cannot skip failed source trigger DDL")
        return SkippedDDL(name:name,sql:String(decoding:query.sql,as:UTF8.self),reason:"ddlPolicy.triggers=skip",tokens:tokens)
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
    var tokens: [DDLToken]? = nil
}

public struct ApplySubpartition: Codable, Equatable {
    public let name: String
    public let method: String
    public let expression: String
    /// Nil is the native default (algorithm 2); only algorithm 1 is stored.
    public var keyAlgorithm: Int? = nil
}

public struct ApplyPartition: Codable, Equatable {
    public let name: String
    public let method: String
    public let expression: String
    public var description: String?
    public var keyAlgorithm: Int? = nil
    public var subpartitions: [ApplySubpartition]? = nil
    func validate() throws {
        _ = try quoted(name)
        try require(["RANGE","RANGE COLUMNS","LIST","LIST COLUMNS","HASH","LINEAR HASH","KEY","LINEAR KEY"].contains(method),"unsupported partition method")
        try require(!expression.isEmpty || method.contains("KEY"),"missing partition expression")
        try require(keyAlgorithm == nil || (keyAlgorithm == 1 && method.contains("KEY")),"invalid partition KEY algorithm")
        if let children=subpartitions {
            try require(!children.isEmpty && (method.hasPrefix("RANGE") || method.hasPrefix("LIST")),"invalid subpartition manifest")
            for child in children {
                _ = try quoted(child.name)
                try require(child.keyAlgorithm == nil || (child.keyAlgorithm == 1 && child.method.contains("KEY")),"invalid subpartition KEY algorithm")
                try require(["HASH","LINEAR HASH","KEY","LINEAR KEY"].contains(child.method) && !child.expression.isEmpty,"invalid subpartition method or expression")
            }
        }
    }
}

struct SchemaTransition: Codable {
    let before: ApplyTable?
    let after: ApplyTable?
    // Retain old journal records. New plans use compact index replacements.
    var afterAlternatives: [ApplyTable]? = nil
    var supportingIndexReplacements: [ForeignKeyIndexReplacement]? = nil
    var removableSupportingIndexes: [ApplyIndex]? = nil
}

enum PartitionChange: Equatable {
    case replace([ApplyPartition])
    case add([ApplyPartition])
    case addHash(Int)
    case maintenance(SQLPartitionMaintenance)
    case drop([String])
    case truncate([String])
    case reorganize([String],[ApplyPartition])
    case coalesce(Int)
    case remove
    case exchange(String,TableName)
}

enum AlterAction: Equatable {
    case ignoredCheck
    case encoding(DDLTableEncoding)
    case tableOption(DDLTableOption)
    case maintenance(SQLAlterMaintenance)
    case addForeignKey(ApplyForeignKey,String?)
    case dropForeignKey(String)
    case add(ApplyColumn,ColumnPlacement)
    case modify(String,ApplyColumn,ColumnPlacement?)
    case drop(String)
    case indexes(IndexChange)
    case renameTable(TableName)
    case renameColumn(String,String)
    case defaultExpression(String,String)
    case defaultValue(String,String?,numeric:Bool = false,bytes:Data? = nil,literalBytes:Data? = nil)
    case primaryKey([String]?)
    case primaryKeyParts([ApplyIndexPart])
    case partition(PartitionChange)
}

struct ObjectDDL: Equatable {
    enum Kind: String { case view = "VIEW", procedure = "PROCEDURE", function = "FUNCTION" }
    enum Operation { case create, replace, alter, drop }
    let kind: Kind
    let operation: Operation
    let name: TableName
    var ifExists = false
    var additionalNames: [TableName] = []
    var ifNotExists = false
    var names: [TableName] { [name]+additionalNames }
}
