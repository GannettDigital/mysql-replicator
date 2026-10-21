import Foundation
import ReplicatorLogging

/// Serial-owner schema cache. The caller supplies a metadata reader, which can
/// use the write session or a separate connection. Never cross a DDL barrier
/// with an old snapshot. This cache is not the durable schema history.
/// No TTL or automatic eviction: the applier is the only target writer. Keep
/// entries until explicit DDL invalidation/replacement or session reconstruction.
final class SchemaMetadataCache {
    var tables: [SQLNameKey: ApplyTable] = [:]

    func table(_ name: TableName, read: (TableName) throws -> ApplyTable?) throws -> ApplyTable? {
        if let cached = tables[name.identity] {
            ApplicationLog.logger.debug(
                "Use cached target schema",
                metadata: ["cache": "hit", "database": .string(name.database), "table": .string(name.table)])
            return cached
        }
        try require(tables.count < maximumCachedTables, "discovered schema limit reached")
        guard let table = try read(name) else { return nil }
        tables[name.identity] = table
        return table
    }
    func invalidate(_ name: TableName) { tables.removeValue(forKey: name.identity) }
    func invalidate(database: String) {
        tables = tables.filter { !SQLTextBytes.equal($0.value.database, database) }
    }
    func invalidateAll() { tables.removeAll(keepingCapacity: true) }
}
