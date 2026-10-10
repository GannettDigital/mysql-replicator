import Foundation
import ReplicatorCapture
import ReplicatorCodec

// Keep discovery, DDL and durable schema reload bounded by the same limit.
let maximumCachedTables = 1024

public struct ApplyError: Error, CustomStringConvertible {
    public let message: String
    public let code: ApplyErrorCode?
    public let mysqlErrorNumber: Int?
    public let sqlState: String?
    public var description: String { code.map { "[\($0.rawValue)] \(message)" } ?? message }
    public init(_ message: String, code: ApplyErrorCode? = nil, mysqlErrorNumber: Int? = nil, sqlState: String? = nil) {
        self.message=message;self.code=code;self.mysqlErrorNumber=mysqlErrorNumber;self.sqlState=sqlState
    }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String, code: ApplyErrorCode? = nil) throws {
    if try !condition() { throw ApplyError(message,code:code) }
}
func quoted(_ name: String) throws -> String {
    try require(!name.isEmpty && name.utf8.count <= 64 && !name.contains("\0") && name.unicodeScalars.allSatisfy { $0.isASCII }, "invalid SQL identifier")
    return "`" + name.replacingOccurrences(of:"`",with:"``") + "`"
}
public struct ApplyColumn: Codable, Equatable {
    public var name: String
    public let type: String
    public var nullable: Bool
    public let collation: String?
    public var characterSet: String? = nil
    public var defaultValue: String? = nil
    public var extra: String? = nil
    public var generationExpression: String? = nil
    var isGenerated: Bool { generationExpression != nil }
    var interpretation: ColumnInterpretation { (try? DMLColumnType(type).interpretation) ?? .signed }
    var width: Int? {
        guard let parsed=try? DMLColumnType(type) else { return nil }
        if parsed.base == "varchar" || parsed.base == "varbinary" { return parsed.arguments[0] }
        return parsed.maximumBytes
    }
    func validate() throws {
        _ = try quoted(name)
        let parsed = try DMLColumnType(type)
        if let expression = generationExpression {
            try require(["VIRTUAL GENERATED","STORED GENERATED"].contains(extra ?? "") && defaultValue == nil,"invalid generated column metadata")
            _ = try DDLExpression.canonical(expression)
        } else {
            try require(extra == nil || extra == "auto_increment" || ((parsed.base == "datetime" || parsed.base == "timestamp") && extra!.range(of:#"^on update CURRENT_TIMESTAMP(?:\([0-6]\))?$"#,options:.regularExpression) != nil), "unsupported column EXTRA attribute")
        }
        if extra == "auto_increment" { try require(parsed.integerBits != nil && !nullable,"invalid auto-increment column") }
        if parsed.isText {
            try require(characterSet == nil || characterSet == "utf8mb4", "unsupported discovered character set; no charset conversion is performed")
            try require(["utf8mb4_bin","utf8mb4_unicode_ci","utf8mb4_general_ci"].contains(collation ?? ""), "unsupported varchar collation")
        } else { try require(collation == nil && characterSet == nil, "encoding on non-text column") }
    }
    func validate(_ value: DecodedValue) throws {
        if value == .null { try require(nullable, "NULL in nonnullable column"); return }
        try DMLColumnType(type).validate(value)
    }
}
public struct ApplyIndexPart: Codable, Equatable {
    public let column: String
    public let prefix: Int?
    public var direction: String = "A"
}
public struct ApplyIndex: Codable, Equatable {
    public let name: String
    public let unique: Bool
    public let parts: [ApplyIndexPart]
    public var type: String = "BTREE"
}
public struct ApplyTable: Codable, Equatable {
    public let database: String
    public let table: String
    public let columns: [ApplyColumn]
    public let primaryKeyColumns: [String]
    /// Legacy single-key convenience for callers constructing a one-column schema.
    public var primaryKey: String { primaryKeyColumns[0] }
    public var defaultCharacterSet: String? = nil
    public var defaultCollation: String? = nil
    public var secondaryIndexes: [ApplyIndex] = []
    public var partitions: [ApplyPartition] = []
    /// Complete connected relationship component, including inbound cascades.
    public var foreignKeys: [ApplyForeignKey] = []
    var identity: String { database + "\0" + table }
    var keyIndexes: [Int] { primaryKeyColumns.map { name in columns.firstIndex { $0.name == name }! } }
    var keyIndex: Int { keyIndexes[0] }
    init(database: String, table: String, columns: [ApplyColumn], primaryKey: String,
         defaultCharacterSet: String? = nil, defaultCollation: String? = nil, secondaryIndexes: [ApplyIndex] = [], partitions: [ApplyPartition] = [], foreignKeys: [ApplyForeignKey] = []) {
        self.init(database:database,table:table,columns:columns,primaryKeyColumns:[primaryKey],
                  defaultCharacterSet:defaultCharacterSet,defaultCollation:defaultCollation,secondaryIndexes:secondaryIndexes,partitions:partitions,foreignKeys:foreignKeys)
    }
    init(database: String, table: String, columns: [ApplyColumn], primaryKeyColumns: [String],
         defaultCharacterSet: String? = nil, defaultCollation: String? = nil, secondaryIndexes: [ApplyIndex] = [], partitions: [ApplyPartition] = [], foreignKeys: [ApplyForeignKey] = []) {
        self.database=database; self.table=table; self.columns=columns; self.primaryKeyColumns=primaryKeyColumns
        self.defaultCharacterSet=defaultCharacterSet; self.defaultCollation=defaultCollation; self.secondaryIndexes=secondaryIndexes
        self.partitions=partitions; self.foreignKeys=foreignKeys
    }
    var sqlName: String { get throws { try quoted(database) + "." + quoted(table) } }
    func validate() throws {
        _ = try sqlName
        try require(!columns.isEmpty && columns.count <= 256 && Set(columns.map(\.name)).count == columns.count,"invalid column manifest")
        for c in columns { try c.validate() }
        try require(foreignKeys.count <= 256,"foreign-key relationship limit exceeded")
        for key in foreignKeys { try key.validate() }
        try require(partitions.count <= 8192 && Set(partitions.map(\.name)).count == partitions.count,"invalid partition manifest")
        for partition in partitions { try partition.validate() }
        try require(secondaryIndexes.count <= 63 && Set(secondaryIndexes.map{$0.name.lowercased()}).count == secondaryIndexes.count,"duplicate or excessive secondary indexes")
        for key in secondaryIndexes {
            _ = try quoted(key.name)
            try require(key.name.uppercased() != "PRIMARY" && key.type == "BTREE" && (1...16).contains(key.parts.count),"unsupported secondary index")
            for part in key.parts {
                guard let column=columns.first(where:{$0.name == part.column}) else { throw ApplyError("index column is absent") }
                try require(part.direction == "A","unsupported descending index")
                if let prefix=part.prefix { try require(column.width != nil && prefix > 0 && prefix <= column.width!,"invalid index prefix") }
            }
        }
        try require((1...16).contains(primaryKeyColumns.count) && Set(primaryKeyColumns).count == primaryKeyColumns.count,"invalid primary-key columns")
        try require(columns.filter{$0.extra == "auto_increment"}.allSatisfy{primaryKeyColumns.contains($0.name)},"auto-increment requires a primary-key column")
        for name in primaryKeyColumns {
            guard let key = columns.first(where:{$0.name == name}) else { throw ApplyError("missing primary key column") }
            let type = try DMLColumnType(key.type)
            try require(!key.nullable && !key.isGenerated && !type.base.hasSuffix("text") && !type.base.hasSuffix("blob"),"primary key requires full nonnullable supported base scalar columns")
        }
    }
}
extension ApplyTable {
    enum CodingKeys: String, CodingKey { case database,table,columns,primaryKey,primaryKeyColumns,defaultCharacterSet,defaultCollation,secondaryIndexes,partitions,foreignKeys }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        database=try c.decode(String.self,forKey:.database); table=try c.decode(String.self,forKey:.table)
        columns=try c.decode([ApplyColumn].self,forKey:.columns)
        if let names = try c.decodeIfPresent([String].self,forKey:.primaryKeyColumns) {
            try require(!c.contains(.primaryKey),"ambiguous primary-key schema")
            primaryKeyColumns=names
        } else { primaryKeyColumns=[try c.decode(String.self,forKey:.primaryKey)] }
        defaultCharacterSet=try c.decodeIfPresent(String.self,forKey:.defaultCharacterSet)
        defaultCollation=try c.decodeIfPresent(String.self,forKey:.defaultCollation)
        secondaryIndexes=try c.decodeIfPresent([ApplyIndex].self,forKey:.secondaryIndexes) ?? []
        partitions=try c.decodeIfPresent([ApplyPartition].self,forKey:.partitions) ?? []
        foreignKeys=try c.decodeIfPresent([ApplyForeignKey].self,forKey:.foreignKeys) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(database,forKey:.database); try c.encode(table,forKey:.table); try c.encode(columns,forKey:.columns)
        if primaryKeyColumns.count == 1 { try c.encode(primaryKey,forKey:.primaryKey) }
        else { try c.encode(primaryKeyColumns,forKey:.primaryKeyColumns) }
        try c.encodeIfPresent(defaultCharacterSet,forKey:.defaultCharacterSet)
        try c.encodeIfPresent(defaultCollation,forKey:.defaultCollation)
        try c.encode(secondaryIndexes,forKey:.secondaryIndexes)
        try c.encode(partitions,forKey:.partitions)
        if !foreignKeys.isEmpty { try c.encode(foreignKeys,forKey:.foreignKeys) }
    }
    func replacing(columns: [ApplyColumn]? = nil, indexes: [ApplyIndex]? = nil, primaryKey: [String]? = nil, partitions: [ApplyPartition]? = nil) -> ApplyTable {
        ApplyTable(database:database,table:table,columns:columns ?? self.columns,primaryKeyColumns:primaryKey ?? primaryKeyColumns,
            defaultCharacterSet:defaultCharacterSet,defaultCollation:defaultCollation,
            secondaryIndexes:(indexes ?? secondaryIndexes).sorted{$0.name.lowercased() < $1.name.lowercased()},partitions:partitions ?? self.partitions,foreignKeys:foreignKeys)
    }
}
public struct TargetConfiguration: Decodable {
    public enum TLSVerification: String, Decodable {
        case verifyIdentity = "verify-identity"
        case verifyCA = "verify-ca"
    }
    public let host: String?
    public let port: Int?
    public let unixSocket: String?
    public let requireTLS: Bool
    public let tlsVerification: TLSVerification
    public let username: String
    public let passwordEnvironment: String?
    public let password: String?
    public let serverHostname: String?
    public let caFile: String?
    /// Optional client LOCK/UNLOCK TABLES; internal MyISAM locking still applies.
    public let explicitTableLocks: Bool
    /// Operator attestation: MySQL 5.7 does not expose this startup option via SQL.
    public let nativeAutoStartDisabled: Bool
    enum CodingKeys: String, CodingKey {case host,port,unixSocket,requireTLS,tlsVerification,username,passwordEnvironment,password,serverHostname,caFile,nativeAutoStartDisabled,targetUUID,explicitTableLocks}
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard !c.contains(.targetUUID) else {throw ApplyError("remove targetUUID from config; target identity is discovered from the verified node")}
        host=try c.decodeIfPresent(String.self,forKey:.host); port=try c.decodeIfPresent(Int.self,forKey:.port)
        unixSocket=try c.decodeIfPresent(String.self,forKey:.unixSocket)
        requireTLS=try c.decodeIfPresent(Bool.self,forKey:.requireTLS) ?? true
        tlsVerification=try c.decodeIfPresent(TLSVerification.self,forKey:.tlsVerification) ?? .verifyIdentity
        username=try c.decode(String.self,forKey:.username)
        passwordEnvironment=try c.decodeIfPresent(String.self,forKey:.passwordEnvironment)
        password=try c.decodeIfPresent(String.self,forKey:.password)
        serverHostname=try c.decodeIfPresent(String.self,forKey:.serverHostname); caFile=try c.decodeIfPresent(String.self,forKey:.caFile)
        explicitTableLocks=try c.decodeIfPresent(Bool.self,forKey:.explicitTableLocks) ?? false
        nativeAutoStartDisabled=try c.decode(Bool.self,forKey:.nativeAutoStartDisabled)
    }
    func validate() throws {
        try require(!username.isEmpty,"invalid target credentials")
        try PasswordConfiguration.validate(password:password,environmentVariable:passwordEnvironment,endpoint:"target")
        if let path = unixSocket {
            try require(host == nil && port == nil,"choose target unixSocket or host/port, not both")
            try require(path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 103,"target unixSocket must be an absolute path of at most 103 UTF-8 bytes without NUL")
        } else {
            try require(!(host ?? "").isEmpty && (1...65535).contains(port ?? 0),"invalid target TCP address")
        }
        if requireTLS {
            if tlsVerification == .verifyIdentity {
                try require(!(serverHostname ?? "").isEmpty,"target verify-identity TLS requires serverHostname")
            } else {
                try require(!(caFile ?? "").isEmpty,"target verify-ca TLS requires an explicit caFile")
                try require(serverHostname == nil || !serverHostname!.isEmpty,"omit target serverHostname or provide a nonempty TLS name")
            }
        } else {
            try require(serverHostname == nil && caFile == nil && tlsVerification == .verifyIdentity,"remove target TLS settings when requireTLS is false")
        }
    }
}
public struct ApplyConfiguration: Decodable {
    public let profile: ReplicationProfile?
    var replicationProfile: ReplicationProfile { profile ?? .mysql84To57MyISAM }
    /// Detailed worker-local applier timings, disabled unless explicitly enabled.
    public let applierProfiling: Bool?
    public let version: Int
    public let source: CaptureConfiguration
    public let target: TargetConfiguration
    public let tables: [ApplyTable]?
    public let stateDirectory: String
    public let maximumRelayBytes: UInt64?
    public let replicateWildIgnoreTable: [String]?
    public let ddlTimeoutSeconds: Int?
    public let ddlPolicy: DDLPolicy?
    public let compatibility: CompatibilityPolicy?
    var compatibilityPolicy: CompatibilityPolicy { compatibility ?? .init() }
    var ddlDeadline: Int { ddlTimeoutSeconds ?? 300 }
    public let storage: StoragePolicy?
    public let batch: BatchPolicy?
    public let targetReconnect: TargetReconnectPolicy?
    var targetReconnectPolicy: TargetReconnectPolicy { targetReconnect ?? .init() }
    public let sourceReconnect: SourceReconnectPolicy?
    public let skipErrors: SkipErrorPolicy?
    var skipErrorPolicy: SkipErrorPolicy { skipErrors ?? .init() }
    var reconnectPolicy: SourceReconnectPolicy { sourceReconnect ?? .init() }
    var batchPolicy: BatchPolicy { batch ?? .init() }
    var policy: StoragePolicy { storage ?? StoragePolicy() }
    public func validate(offline: Bool = false) throws {
        try require(version == 2 && tables == nil && source.version == 2 && source.tables == nil && !stateDirectory.isEmpty,"use configuration version 2 without tables/schema lists; automatic discovery replaces the legacy allowlist")
        _ = try source.validate(connection:!offline)
        try target.validate()
        try require(target.nativeAutoStartDisabled,"operator must disable automatic native replication start")
        try require((UInt64(1_048_576)...UInt64(1_073_741_824)).contains(maximumRelayBytes ?? 268_435_456),"relay limit must be 1 MiB to 1 GiB")
        try require((1...86400).contains(ddlDeadline),"DDL timeout must be 1 to 86400 seconds")
        try (ddlPolicy ?? DDLPolicy()).validate()
        try compatibilityPolicy.validate()
        if replicationProfile.transactional {
            try require(!target.explicitTableLocks,"InnoDB profile cannot use explicit table locks")
            try require(compatibilityPolicy.collations.isEmpty,"reverse profile preserves source collations; translation is not supported")
        }
        if replicationProfile.sourceContract.requiresHistoricalSchema {
            try require(source.mode == "gtid","MySQL 5.7 source profiles require GTID positioning")
        }
        _ = try TableFilter(replicateWildIgnoreTable ?? [])
        try policy.validate()
        try batchPolicy.validate()
        try reconnectPolicy.validate()
        try targetReconnectPolicy.validate(endpoint:"target")
        try skipErrorPolicy.validate()
    }
}

struct Mutation {
    let table: ApplyTable
    let row: DecodedRow
    let eventOffset: String
    let rowIndex: Int
}
enum DMLPlan {
    /// Validate the entire group before the first mutation. The MyISAM contract
    /// permits one statement/table; transactional targets preserve whole groups.
    static func make(_ group: CompleteTransaction, tables: [ApplyTable]) throws -> [Mutation] {
        var plans: [String:DMLTablePlan] = [:]
        for table in tables {
            try require(plans[table.identity] == nil,"duplicate table manifest")
            plans[table.identity] = try DMLTablePlan(table)
        }
        return try make(group,tables:plans)
    }
    static func make(_ group: CompleteTransaction, tables: [String:DMLTablePlan], transactional: Bool = false) throws -> [Mutation] {
        try require(group.outcome == .committed && group.gtid != nil && !group.anonymous,"unsupported transaction identity/outcome")
        var statementEnds = 0, includedEvents = 0
        for event in group.events where event.rowFlags != nil {
            if event.rowFlags! & 1 != 0 { statementEnds += 1 }
            if !event.replicationFiltered { includedEvents += 1 }
        }
        if includedEvents == 0 { return [] }
        try require(statementEnds >= 1,"source group lacks a statement boundary")
        try require(transactional || statementEnds == 1,"only single-statement source groups are supported",code:.multipleStatements)
        var result: [Mutation] = []
        var firstIdentity: String?
        for event in group.events where event.rowFlags != nil && !event.replicationFiltered {
            guard let database = event.database, let name = event.table,
                  let plan = tables[database + "\0" + name] else { throw ApplyError("row event outside configured scope") }
            if !event.rows.isEmpty {
                let identity = plan.table.identity
                if let firstIdentity { try require(transactional || firstIdentity == identity,"initial applier requires a single-table DML statement",code:.multipleTables) }
                else { firstIdentity = identity }
            }
            for (index,row) in event.rows.enumerated() {
                try require(row.operation == "insert" || row.operation == "update" || row.operation == "delete","unsupported row operation")
                try require((row.before != nil) == (row.operation != "insert") && (row.after != nil) == (row.operation != "delete"),"invalid row image shape")
                if let before = row.before { try plan.validate(before) }
                if let after = row.after { try plan.validate(after) }
                result.append(Mutation(table:plan.table,row:row,eventOffset:event.offset,rowIndex:index))
            }
        }
        try require(!result.isEmpty,"initial applier requires a single-table DML statement")
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
    public var capacityCheckEveryTransactions: Int = 1000
    public var capacityCheckIntervalSeconds: Int = 5
    public init() {}
    enum CodingKeys: String, CodingKey {case maximumSQLiteBytes, minimumFreeDiskBytes, pruneAtPercent, historyRetentionSeconds, snapshotEveryTransactions, capacityCheckEveryTransactions, capacityCheckIntervalSeconds}
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        maximumSQLiteBytes = try c.decodeIfPresent(Int64.self,forKey:.maximumSQLiteBytes) ?? maximumSQLiteBytes
        minimumFreeDiskBytes = try c.decodeIfPresent(Int64.self,forKey:.minimumFreeDiskBytes) ?? minimumFreeDiskBytes
        pruneAtPercent = try c.decodeIfPresent(Int.self,forKey:.pruneAtPercent) ?? pruneAtPercent
        historyRetentionSeconds = try c.decodeIfPresent(Int.self,forKey:.historyRetentionSeconds) ?? historyRetentionSeconds
        snapshotEveryTransactions = try c.decodeIfPresent(Int.self,forKey:.snapshotEveryTransactions) ?? snapshotEveryTransactions
        capacityCheckEveryTransactions = try c.decodeIfPresent(Int.self,forKey:.capacityCheckEveryTransactions) ?? capacityCheckEveryTransactions
        capacityCheckIntervalSeconds = try c.decodeIfPresent(Int.self,forKey:.capacityCheckIntervalSeconds) ?? capacityCheckIntervalSeconds
    }
    func validate() throws {
        try require((8*1024*1024...1024*1024*1024).contains(maximumSQLiteBytes),"SQLite limit must be 8 MiB to 1 GiB")
        try require((1*1024*1024...Int64.max/2).contains(minimumFreeDiskBytes),"invalid free-disk reserve")
        try require((1...10000).contains(capacityCheckEveryTransactions) && (1...60).contains(capacityCheckIntervalSeconds),"invalid capacity inspection interval")
        try require((50...90).contains(pruneAtPercent) && (1...31536000).contains(historyRetentionSeconds) && (1...10000).contains(snapshotEveryTransactions),"invalid retention/checkpoint policy")
    }
}
