import Foundation
import CReplicatorCodec

/// File positions are only meaningful within the same source history. This
/// value carries no assertion about durability, execution, or source lineage.
public struct BinlogCoordinate: Equatable, Encodable {
    public let file: String
    public let position: UInt64
    public init(file: String, position: UInt64) { self.file = file; self.position = position }
    private enum Keys: String, CodingKey { case file, position }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(file, forKey: .file)
        try c.encode(String(position), forKey: .position)
    }
}

public struct SourceGTID: Equatable, Encodable {
    public let sid: String
    public let sequence: String
    public let flags: UInt32
}

public struct QueryControl: Equatable, Encodable {
    public let database: String?
    public let sql: Data
    public let errorCode: UInt32
    /// Byte-exact status; typed context is available through the Rust adapter.
    public let statusVariables: Data
}

public enum BinlogControl: Equatable, Encodable {
    case formatDescription, previousGTIDs, stop
    case gtid(SourceGTID)
    case anonymousGTID(flags: UInt32)
    case query(QueryControl)
    case xid(String)
    case rotate(BinlogCoordinate)

    private enum Keys: String, CodingKey { case kind, gtid, flags, query, xid, destination }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .formatDescription: try c.encode("formatDescription", forKey: .kind)
        case .previousGTIDs: try c.encode("previousGTIDs", forKey: .kind)
        case .stop: try c.encode("stop", forKey: .kind)
        case .gtid(let gtid):
            try c.encode("gtid", forKey: .kind); try c.encode(gtid, forKey: .gtid)
        case .anonymousGTID(let flags):
            try c.encode("anonymousGTID", forKey: .kind); try c.encode(flags, forKey: .flags)
        case .query(let query):
            try c.encode("query", forKey: .kind); try c.encode(query, forKey: .query)
        case .xid(let xid):
            try c.encode("xid", forKey: .kind); try c.encode(xid, forKey: .xid)
        case .rotate(let destination):
            try c.encode("rotate", forKey: .kind); try c.encode(destination, forKey: .destination)
        }
    }
}

public struct QuerySessionContext {
    public let sqlMode: UInt64
    public let clientCharset: UInt32
    public let connectionCollation: UInt32
    public let serverCollation: UInt32
    public let databaseCollation: UInt32?
    public let defaultUTF8MB4Collation: UInt32
    public init(query: QueryControl) throws {
        var value=rc_query_context()
        let status=query.statusVariables.withUnsafeBytes {bytes in
            rc_query_context_decode(bytes.bindMemory(to:UInt8.self).baseAddress,UInt64(bytes.count),&value)
        }
        let required:UInt32=(1<<1)|(1<<4) // Q_SQL_MODE_CODE and Q_CHARSET_CODE
        guard status==0, value.present & required == required else {
            throw NSError(domain:"QuerySessionContext",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"missing, unknown or malformed DDL query context"])
        }
        sqlMode=value.sql_mode;clientCharset=value.charset_client
        connectionCollation=value.collation_connection;serverCollation=value.collation_server
        databaseCollation=value.present & (1<<8) != 0 ? value.collation_database : nil
        defaultUTF8MB4Collation=value.present & (1<<18) != 0 ? value.default_collation_utf8mb4 : 45
    }
}
