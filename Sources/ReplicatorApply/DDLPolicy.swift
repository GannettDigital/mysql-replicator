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
    public var triggers: String = "reject"
    public var events: String = "reject"
    public init() {}
    enum CodingKeys: String, CodingKey { case triggers, events }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        triggers = try c.decodeIfPresent(String.self,forKey:.triggers) ?? "reject"
        events = try c.decodeIfPresent(String.self,forKey:.events) ?? "reject"
        try validate()
    }
    func validate() throws {
        try require(triggers == "reject", "ddlPolicy.triggers must be reject: ordinary target SQL fires triggers")
        try require(events == "reject", "ddlPolicy.events must be reject: scheduled target writes are unsupported")
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

struct SchemaTransition {
    let before: ApplyTable?
    let after: ApplyTable?
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
