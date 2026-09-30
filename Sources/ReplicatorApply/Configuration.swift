import Foundation
import ReplicatorCapture
import ReplicatorCodec

public struct ApplyError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ApplyError(message) }
}
func quoted(_ name: String) throws -> String {
    try require(!name.isEmpty && name.utf8.count <= 64 && !name.contains("\0") && name.unicodeScalars.allSatisfy { $0.isASCII }, "invalid SQL identifier")
    return "`" + name.replacingOccurrences(of:"`",with:"``") + "`"
}
public struct ApplyColumn: Codable, Equatable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let collation: String?
    public var characterSet: String? = nil
    var interpretation: ColumnInterpretation {
        if type.hasPrefix("varchar(") { return .utf8 }
        if type.hasPrefix("varbinary(") { return .binary }
        return type.hasSuffix(" unsigned") ? .unsigned : .signed
    }
    var width: Int? {
        guard let a = type.firstIndex(of:"("), let b = type.firstIndex(of:")") else { return nil }
        return Int(type[type.index(after:a)..<b])
    }
    func validate() throws {
        _ = try quoted(name)
        let integer = ["int","int unsigned","bigint","bigint unsigned"].contains(type)
        let string = type.range(of:#"^(varchar|varbinary)\([1-9][0-9]*\)$"#,options:.regularExpression) != nil
        try require(integer || (string && (1...16383).contains(width ?? 0)), "unsupported declared column type")
        if interpretation == .utf8 {
            try require(characterSet == nil || characterSet == "utf8mb4", "unsupported discovered character set; no charset conversion is performed")
            try require(["utf8mb4_bin","utf8mb4_unicode_ci","utf8mb4_general_ci"].contains(collation ?? ""), "unsupported varchar collation")
        } else { try require(collation == nil && characterSet == nil, "encoding on non-text column") }
    }
    func validate(_ value: DecodedValue) throws {
        if value == .null { try require(nullable, "NULL in nonnullable column"); return }
        switch (interpretation,value) {
        case (.signed,.signed(let n)):
            try require(type == "bigint" || (Int64(Int32.min)...Int64(Int32.max)).contains(n), "signed value out of range")
        case (.unsigned,.unsigned(let n)):
            try require(type == "bigint unsigned" || n <= UInt64(UInt32.max), "unsigned value out of range")
        case (.utf8,.text(let text)):
            try require(text.unicodeScalars.count <= (width ?? 0), "varchar value exceeds declared length")
        case (.binary,.binary(let bytes)):
            try require(bytes.count <= (width ?? 0), "binary value exceeds declared length")
        default: throw ApplyError("missing or incompatible full row value")
        }
    }
}
public struct ApplyTable: Codable, Equatable {
    public let database: String
    public let table: String
    public let columns: [ApplyColumn]
    public let primaryKey: String
    public var defaultCharacterSet: String? = nil
    public var defaultCollation: String? = nil
    var identity: String { database + "\0" + table }
    var keyIndex: Int { columns.firstIndex { $0.name == primaryKey }! }
    var sqlName: String { get throws { try quoted(database) + "." + quoted(table) } }
    func validate() throws {
        _ = try sqlName
        try require(!columns.isEmpty && columns.count <= 256 && Set(columns.map(\.name)).count == columns.count,"invalid column manifest")
        for c in columns { try c.validate() }
        guard let key = columns.first(where:{$0.name == primaryKey}) else { throw ApplyError("missing primary key column") }
        try require(!key.nullable && [.signed,.unsigned].contains(key.interpretation),"initial applier requires one nonnullable integer primary key")
    }
}
public struct TargetConfiguration: Decodable {
    public let host: String
    public let port: Int
    public let username: String
    public let passwordEnvironment: String
    public let serverHostname: String
    public let caFile: String?
    /// Operator attestation: MySQL 5.7 does not expose this startup option via SQL.
    public let nativeAutoStartDisabled: Bool
    enum CodingKeys: String, CodingKey {case host,port,username,passwordEnvironment,serverHostname,caFile,nativeAutoStartDisabled,targetUUID}
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard !c.contains(.targetUUID) else {throw ApplyError("remove targetUUID from config; target identity is discovered from the verified node")}
        host=try c.decode(String.self,forKey:.host); port=try c.decode(Int.self,forKey:.port)
        username=try c.decode(String.self,forKey:.username); passwordEnvironment=try c.decode(String.self,forKey:.passwordEnvironment)
        serverHostname=try c.decode(String.self,forKey:.serverHostname); caFile=try c.decodeIfPresent(String.self,forKey:.caFile)
        nativeAutoStartDisabled=try c.decode(Bool.self,forKey:.nativeAutoStartDisabled)
    }
}
public struct ApplyConfiguration: Decodable {
    public let version: Int
    public let source: CaptureConfiguration
    public let target: TargetConfiguration
    public let tables: [ApplyTable]?
    public let stateDirectory: String
    public let maximumRelayBytes: UInt64?
    public let storage: StoragePolicy?
    var policy: StoragePolicy { storage ?? StoragePolicy() }
    public func validate() throws {
        try require(version == 2 && tables == nil && source.version == 2 && source.tables == nil && !stateDirectory.isEmpty,"use configuration version 2 without tables/schema lists; automatic discovery replaces the legacy allowlist")
        _ = try source.validate()
        try require(!target.host.isEmpty && (1...65535).contains(target.port) && !target.username.isEmpty && !target.passwordEnvironment.isEmpty && !target.serverHostname.isEmpty,"invalid target connection")
        try require(target.nativeAutoStartDisabled,"operator must disable automatic native replication start")
        try require((UInt64(1_048_576)...UInt64(1_073_741_824)).contains(maximumRelayBytes ?? 268_435_456),"relay limit must be 1 MiB to 1 GiB")
        try policy.validate()
    }
}

struct Mutation {
    let table: ApplyTable
    let row: DecodedRow
    let eventOffset: String
    let rowIndex: Int
}
enum DMLPlan {
    /// Validate the entire group before the first mutation. One source statement
    /// may span several row events/rows, but multi-statement groups are rejected.
    static func make(_ group: CompleteTransaction, tables: [ApplyTable]) throws -> [Mutation] {
        try require(group.outcome == .committed && group.gtid != nil && !group.anonymous,"unsupported transaction identity/outcome")
        let rowEvents = group.events.filter { !$0.rows.isEmpty }
        try require(rowEvents.filter { ($0.rowFlags ?? 0) & 1 != 0 }.count == 1,"only single-statement source groups are supported")
        var result: [Mutation] = []
        for event in rowEvents {
            guard let table = tables.first(where:{$0.database == event.database && $0.table == event.table}) else { throw ApplyError("row event outside configured scope") }
            for (index,row) in event.rows.enumerated() {
                try require(["insert","update","delete"].contains(row.operation),"unsupported row operation")
                try require((row.before != nil) == (row.operation != "insert") && (row.after != nil) == (row.operation != "delete"),"invalid row image shape")
                for values in [row.before,row.after].compactMap({$0}) {
                    try require(values.count == table.columns.count,"row/manifest column count differs")
                    for (column,value) in zip(table.columns,values) { try column.validate(value) }
                }
                result.append(Mutation(table:table,row:row,eventOffset:event.offset,rowIndex:index))
            }
        }
        try require(!result.isEmpty && Set(result.map { $0.table.identity }).count == 1,"initial applier requires a single-table DML statement")
        return result
    }
}

/// Swift String equality folds canonically equivalent Unicode sequences. Row
/// verification must compare stored UTF-8 bytes, including trailing spaces.
func exactImage(_ lhs: [DecodedValue]?, _ rhs: [DecodedValue]?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    guard lhs.count == rhs.count else { return false }
    return zip(lhs,rhs).allSatisfy { a,b in
        if case .text(let x) = a, case .text(let y) = b { return x.utf8.elementsEqual(y.utf8) }
        return a == b
    }
}

public struct StoragePolicy: Codable {
    public var maximumSQLiteBytes: Int64 = 256 * 1024 * 1024
    public var minimumFreeDiskBytes: Int64 = 512 * 1024 * 1024
    public var pruneAtPercent: Int = 80
    public var historyRetentionSeconds: Int = 86400
    public var snapshotEveryTransactions: Int = 1000
    public init() {}
    enum CodingKeys: String, CodingKey {case maximumSQLiteBytes, minimumFreeDiskBytes, pruneAtPercent, historyRetentionSeconds, snapshotEveryTransactions}
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        maximumSQLiteBytes = try c.decodeIfPresent(Int64.self,forKey:.maximumSQLiteBytes) ?? maximumSQLiteBytes
        minimumFreeDiskBytes = try c.decodeIfPresent(Int64.self,forKey:.minimumFreeDiskBytes) ?? minimumFreeDiskBytes
        pruneAtPercent = try c.decodeIfPresent(Int.self,forKey:.pruneAtPercent) ?? pruneAtPercent
        historyRetentionSeconds = try c.decodeIfPresent(Int.self,forKey:.historyRetentionSeconds) ?? historyRetentionSeconds
        snapshotEveryTransactions = try c.decodeIfPresent(Int.self,forKey:.snapshotEveryTransactions) ?? snapshotEveryTransactions
    }
    func validate() throws {
        try require((8*1024*1024...1024*1024*1024).contains(maximumSQLiteBytes),"SQLite limit must be 8 MiB to 1 GiB")
        try require((1*1024*1024...Int64.max/2).contains(minimumFreeDiskBytes),"invalid free-disk reserve")
        try require((50...90).contains(pruneAtPercent) && (1...31536000).contains(historyRetentionSeconds) && (1...10000).contains(snapshotEveryTransactions),"invalid retention/checkpoint policy")
    }
}
