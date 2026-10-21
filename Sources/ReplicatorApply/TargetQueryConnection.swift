import Foundation
import MySQLNIO

/// Independent connections for server metadata and application execution.
/// Session-local queries must stay with their owning write connection.
protocol TargetQueryConnection: AnyObject {
    func execute(_ sql: String, binds: [MySQLData], textProtocol: Bool, rawSQL: Data?) throws
        -> ([MySQLRow], UInt64?)
}

final class MySQLTargetQueryConnection: TargetQueryConnection {
    let connection: MySQLConnection
    init(_ connection: MySQLConnection) { self.connection = connection }
    func execute(_ sql: String, binds: [MySQLData], textProtocol: Bool, rawSQL: Data?) throws
        -> ([MySQLRow], UInt64?)
    {
        if let rawSQL { return (try connection.simpleQueryBytes(Array(rawSQL)).wait(), nil) }
        if textProtocol { return (try connection.simpleQuery(sql).wait(), nil) }
        var affected: UInt64?
        let rows = try connection.cachedQuery(sql, binds, onMetadata: { affected = $0.affectedRows }).wait()
        return (rows, affected)
    }
}

/// Discards commands without retaining SQL or row values. No affected-row count
/// is invented. Only the preview uses this result; it never marks data applied.
final class DiscardTargetQueryConnection: TargetQueryConnection {
    private(set) var commandsDiscarded = 0
    func execute(_ sql: String, binds: [MySQLData], textProtocol: Bool, rawSQL: Data?) throws
        -> ([MySQLRow], UInt64?)
    {
        commandsDiscarded += 1
        return ([], nil)
    }
}

struct TargetQueryConnections {
    let reads: any TargetQueryConnection
    let writes: any TargetQueryConnection
    let metadataOnly: Bool

    func usesMetadataConnection(_ sql: String, mutation: Bool, rawSQL: Data?, metadata: Bool = false) -> Bool {
        guard !mutation, rawSQL == nil else { return false }
        if !metadataOnly { return metadata }
        // A preview has no real write session. Only permitted SELECT/SHOW
        // probes use the real metadata connection; writes use the discard sink.
        guard sql.hasPrefix("SELECT ") || sql.hasPrefix("SHOW ") else { return false }
        let text = sql.uppercased()
        return !text.contains("GET_LOCK(") && !text.contains("RELEASE_LOCK(")
    }

    func execute(
        _ sql: String, binds: [MySQLData], textProtocol: Bool, rawSQL: Data?, mutation: Bool, metadata: Bool = false
    ) throws
        -> ([MySQLRow], UInt64?)
    {
        let metadata = usesMetadataConnection(sql, mutation: mutation, rawSQL: rawSQL, metadata: metadata)
        if metadata && metadataOnly { try DryRunAccess.check(sql, mutation: false, rawSQL: nil) }
        return try (metadata ? reads : writes).execute(
            sql, binds: binds, textProtocol: textProtocol, rawSQL: rawSQL)
    }
}
