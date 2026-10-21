import Foundation
import MySQLNIO
import ReplicatorCodec

/// Reuse identical server metadata reads only within one synchronous discovery.
/// Nested FK validation shares the scope. No result survives success or failure.
/// Session-local queries and target writes never enter this cache.
final class DiscoveryReads {
    struct Key: Hashable {
        let sql: Data
        let bindings: [Data]
        let textProtocol: Bool
        init?(_ sql: String, binds: [MySQLData], textProtocol: Bool) {
            // Discovery parameters are identifiers. Bypass other parameter types.
            guard sql.hasPrefix("SELECT "), sql.contains("information_schema."),
                binds.allSatisfy({ $0.type == .varString && $0.format == .binary && $0.buffer != nil })
            else { return nil }
            self.sql = Data(sql.utf8)
            bindings = binds.map { Data($0.buffer!.readableBytesView) }
            self.textProtocol = textProtocol
        }
    }
    typealias Result = ([MySQLRow], UInt64?)
    private var entries: [Key: Result] = [:]
    private var bytes = 0
    private var depth = 0
    private(set) var table: TableName?
    let maximumBytes: Int
    init(maximumBytes: Int = 16 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    func scope<T>(_ table: TableName, _ body: () throws -> T) rethrows -> T {
        let previous = self.table
        self.table = table
        depth += 1
        defer {
            self.table = previous
            depth -= 1
            if depth == 0 {
                entries.removeAll(keepingCapacity: false)
                bytes = 0
            }
        }
        return try body()
    }

    func read(
        _ sql: String, binds: [MySQLData], textProtocol: Bool, timings: StageTimings,
        _ body: () throws -> Result
    ) rethrows -> Result {
        guard depth > 0, let key = Key(sql, binds: binds, textProtocol: textProtocol) else { return try body() }
        if let value = entries[key] { return timings.measure("target.metadata.cache_hit") { value } }
        let value = try body()
        // Include row/field overhead as well as result bytes. A full cache merely
        // bypasses insertion; it never rejects a valid schema or grows unbounded.
        var cost = key.sql.count
        for binding in key.bindings { cost += binding.count }
        for row in value.0 {
            cost += 128
            for value in row.values { cost += 128 + (value?.readableBytes ?? 0) }
            for column in row.columnDefinitions { cost += column.name.utf8.count + column.table.utf8.count }
        }
        if entries.count < 2048 && cost <= maximumBytes - bytes {
            entries[key] = value
            bytes += cost
        }
        return value
    }
}
