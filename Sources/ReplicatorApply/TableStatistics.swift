import Foundation
import ReplicatorCodec
import ReplicatorLogging

public struct TableStatisticsEntry: Codable {
    public struct Durable: Codable, Equatable {
        public var insertRows: Int64 = 0
        public var updateRows: Int64 = 0
        public var deleteRows: Int64 = 0
        public var completedTransactions: Int64 = 0
        public var filteredTransactions: Int64 = 0
        public var policySkippedTransactions: Int64 = 0
        public var errorSkippedTransactions: Int64 = 0
        public var ddl: [String: Int64] = [:]
    }
    public struct ProcessCounts: Codable {
        public var observedEvents: Int64 = 0
        public var decodedRows: Int64 = 0
        public var filteredRows: Int64 = 0
        public var filteredRowEventsWithoutRowCount: Int64 = 0
        public var plannedInsertRows: Int64 = 0
        public var plannedUpdateRows: Int64 = 0
        public var plannedDeleteRows: Int64 = 0
        public var plannedDDL: [String: Int64] = [:]
        public var queryFailures: Int64 = 0
        public var blockedRuns: Int64 = 0
        public var planningFailures: Int64 = 0
        public var schemaQueries: Int64 = 0
        public var schemaQuerySeconds: Double = 0
        public var targetQueries: Int64 = 0
        public var targetQuerySeconds: Double = 0
        public var columnTypes: [String] = []
        public var indexTypes: [String] = []
    }
    public let id: Int
    public let database: String?
    public let table: String?
    public var durable = Durable()
    public var process = ProcessCounts()
    public var sampledAt: Double = 0
    public var processID: String
}
public struct TableStatisticsSummary: Encodable {
    public let processID: String
    public let maximumTableEntries: Int
    public let namedEntries: Int
    public let limitReached: Bool
    public let sinceTransaction: Int
    public let transactionsNotRecorded: Int
}
public struct TableStatisticsPage: Encodable {
    public let summary: TableStatisticsSummary
    public let offset: Int
    public let nextOffset: Int?
    public let entries: [TableStatisticsEntry]
}

/// Durable totals change only after the checkpoint commit. Other fields describe
/// attempts in this process, and can repeat after a reconnect. Queries hold this
/// lock only to add measurements, never while waiting on the target.
final class TableStatistics: @unchecked Sendable {
    let maximum: Int
    let processID = UUID().uuidString
    private let lock = NSLock()
    private var names: [SQLNameKey: Int] = [:]
    private var entries: [Int: TableStatisticsEntry] = [:]
    private var unsaved = Set<Int>([-1, 0])
    private var warningPending = false
    private var warned = false
    private var since = 0, omitted = 0
    private let warn: (Int) -> Void
    init(maximum: Int, warning: ((Int) -> Void)? = nil) {
        self.maximum = maximum
        warn =
            warning ?? { limit in
                ApplicationLog.logger.warning(
                    "Table statistics limit reached; additional names use the overflow total",
                    metadata: ["limit": .string(String(limit)), "configurationKey": "statistics.maximumTableEntries"])
            }
        entries[-1] = TableStatisticsEntry(id: -1, database: nil, table: nil, processID: processID)
        entries[0] = TableStatisticsEntry(id: 0, database: nil, table: nil, processID: processID)
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            let warning = warningPending
            warningPending = false
            lock.unlock()
            if warning { warn(maximum) }
        }
        return try body()
    }
    private func checkLimit() {
        if names.count == maximum && !warned {
            warned = true
            warningPending = true
        }
    }
    private func id(_ name: TableName?) -> Int {
        guard let name else { return 0 }
        if let id = names[name.identity] { return id }
        // Identifier length also bounds memory for malformed input.
        guard names.count < maximum, name.database.utf8.count <= 256, name.table.utf8.count <= 256 else { return -1 }
        let id = names.count + 1
        names[name.identity] = id
        entries[id] = TableStatisticsEntry(id: id, database: name.database, table: name.table, processID: processID)
        unsaved.insert(id)
        checkLimit()
        return id
    }
    private func name(_ event: DecodedEvent) -> TableName? {
        guard let db = event.database else { return nil }
        return TableName(database: db, table: event.table ?? "")
    }
    func restore(_ saved: [TableStatisticsEntry], since: Int, omitted: Int) throws {
        try locked {
            try require(
                saved.filter { $0.id > 0 }.count <= maximum,
                "saved table statistics exceed statistics.maximumTableEntries; increase the setting")
            for var entry in saved {
                if entry.id > 0 {
                    guard let db = entry.database, let table = entry.table,
                        db.utf8.count <= 256, table.utf8.count <= 256
                    else { throw ApplyError("invalid saved table statistics identity") }
                    names[.table(db, table)] = entry.id
                }
                entry.process = .init()
                entry.processID = processID
                entries[entry.id] = entry
            }
            try require(Set(entries.keys) == Set(-1...names.count), "invalid saved table statistics IDs")
            unsaved = Set(entries.keys).subtracting(saved.map(\.id))
            self.since = since
            self.omitted = omitted
            checkLimit()
        }
    }
    func observe(_ event: DecodedEvent) {
        locked {
            let key = id(name(event))
            entries[key]!.process.observedEvents += 1
            entries[key]!.process.decodedRows += Int64(event.rows.count)
            if event.replicationFiltered {
                entries[key]!.process.filteredRows += Int64(event.rows.count)
                if event.rows.isEmpty && [20, 21, 22, 23, 24, 25, 30, 31, 32, 39].contains(event.eventType) {
                    entries[key]!.process.filteredRowEventsWithoutRowCount += 1
                }
            }
        }
    }
    func plan(_ mutations: [Mutation]) {
        locked {
            for mutation in mutations {
                let key = id(TableName(database: mutation.table.database, table: mutation.table.table))
                switch mutation.row.operation {
                case "insert": entries[key]!.process.plannedInsertRows += 1
                case "update": entries[key]!.process.plannedUpdateRows += 1
                case "delete": entries[key]!.process.plannedDeleteRows += 1
                default: break
                }
            }
        }
    }
    func planDDL(_ plan: PreparedDDL) {
        locked {
            for key in Set(plan.statisticsNames.map { id($0) }) {
                entries[key]!.process.plannedDDL[plan.statement.statisticsOperation, default: 0] += 1
            }
        }
    }
    func schema(_ table: ApplyTable) {
        locked {
            let key = id(TableName(database: table.database, table: table.table))
            let types = table.columns.map { (try? DMLColumnType($0).base) ?? "other" }
            let indexes =
                table.secondaryIndexes.map { index -> String in
                    ["BTREE", "HASH", "FULLTEXT", "RTREE", "SPATIAL"].contains(index.type) ? index.type : "OTHER"
                } + (table.primaryKeyColumns.isEmpty ? [] : ["PRIMARY"])
            entries[key]!.process.columnTypes = Array(Set(entries[key]!.process.columnTypes + types)).sorted()
            entries[key]!.process.indexTypes = Array(Set(entries[key]!.process.indexTypes + indexes)).sorted()
        }
    }
    func query(seconds: Double, schema: Bool, table: TableName? = nil, failed: Bool) {
        locked {
            let key = id(table)
            if schema {
                entries[key]!.process.schemaQueries += 1
                entries[key]!.process.schemaQuerySeconds += seconds
            } else {
                entries[key]!.process.targetQueries += 1
                entries[key]!.process.targetQuerySeconds += seconds
            }
            if failed { entries[key]!.process.queryFailures += 1 }
        }
    }
    func failure(planning: Bool = false, table: TableName? = nil) {
        locked {
            let key = id(table)
            if planning { entries[key]!.process.planningFailures += 1 } else { entries[key]!.process.blockedRuns += 1 }
        }
    }
    struct Completion {
        let group: CompleteTransaction
        let rows: Int
        var outcome: ApplyCounters.Outcome = .applied
        var ddl: PreparedDDL? = nil
    }
    /// Make copies of touched totals only. A failed SQLite commit leaves the
    /// published durable totals unchanged. New empty identities are harmless.
    func completing(_ completions: [Completion]) -> [Int: TableStatisticsEntry] {
        locked {
            var updates: [Int: TableStatisticsEntry] = [:]
            for completion in completions {
                var touched = Set<Int>()
                var remaining = completion.rows
                for event in completion.group.events {
                    if event.table != nil { touched.insert(id(name(event))) }
                    guard !event.replicationFiltered, completion.outcome == .applied else { continue }
                    let key = id(name(event))
                    for row in event.rows where remaining > 0 {
                        if updates[key] == nil { updates[key] = entries[key]! }
                        switch row.operation {
                        case "insert": updates[key]!.durable.insertRows += 1
                        case "update": updates[key]!.durable.updateRows += 1
                        case "delete": updates[key]!.durable.deleteRows += 1
                        default: break
                        }
                        touched.insert(key)
                        remaining -= 1
                    }
                }
                if let ddl = completion.ddl { touched = Set(ddl.statisticsNames.map { id($0) }) }
                if touched.isEmpty {
                    touched.insert(id(completion.group.events.first(where: { $0.database != nil }).flatMap(name)))
                }
                for key in touched {
                    if updates[key] == nil { updates[key] = entries[key]! }
                    updates[key]!.durable.completedTransactions += 1
                    switch completion.outcome {
                    case .applied: break
                    case .filtered: updates[key]!.durable.filteredTransactions += 1
                    case .policySkipped: updates[key]!.durable.policySkippedTransactions += 1
                    case .errorSkipped: updates[key]!.durable.errorSkippedTransactions += 1
                    }
                    if let ddl = completion.ddl {
                        updates[key]!.durable.ddl[ddl.statement.statisticsOperation, default: 0] += 1
                    }
                }
            }
            for key in unsaved where updates[key] == nil { updates[key] = entries[key]! }
            return updates
        }
    }
    func accept(_ updates: [Int: TableStatisticsEntry]) {
        locked {
            for (id, entry) in updates {
                entries[id]!.durable = entry.durable
                unsaved.remove(id)
            }
        }
    }
    var all: [TableStatisticsEntry] { locked { Array(entries.values) } }
    private var compact: TableStatisticsSummary {
        .init(
            processID: processID, maximumTableEntries: maximum, namedEntries: names.count,
            limitReached: names.count == maximum, sinceTransaction: since, transactionsNotRecorded: omitted)
    }
    var summary: TableStatisticsSummary { locked { compact } }
    func page(offset: Int, limit: Int) -> TableStatisticsPage {
        locked {
            let total = names.count + 2
            let end = min(total, offset + limit)
            var values = offset < end ? (offset..<end).compactMap { entries[$0 - 1] } : []
            let sampledAt = Date().timeIntervalSince1970
            for index in values.indices { values[index].sampledAt = sampledAt }
            return .init(summary: compact, offset: offset, nextOffset: end < total ? end : nil, entries: values)
        }
    }
}

extension DDLStatement {
    var statisticsOperation: String {
        switch self {
        case .versionCommentNoop: return "VERSION_COMMENT_NOOP"
        case .createDatabase: return "CREATE_DATABASE"
        case .alterDatabase: return "ALTER_DATABASE"
        case .dropDatabase: return "DROP_DATABASE"
        case .object(let object): return String(describing: object.operation).uppercased() + "_" + object.kind.rawValue
        case .create, .createIfAbsent, .createLike: return "CREATE_TABLE"
        case .rename, .renameMany: return "RENAME_TABLE"
        case .drop, .dropIfPresent, .dropMany: return "DROP_TABLE"
        case .truncate: return "TRUNCATE_TABLE"
        default: return "ALTER_TABLE"
        }
    }
}
extension PreparedDDL {
    var statisticsNames: [TableName?] {
        var names = [
            statement.name, before.map { TableName(database: $0.database, table: $0.table) },
            after.map { TableName(database: $0.database, table: $0.table) },
        ].compactMap { $0 }
        names += additional.flatMap { change in
            [change.before, change.after].compactMap { $0 }.map {
                TableName(database: $0.database, table: $0.table)
            }
        }
        if let database { names.append(TableName(database: database.name, table: "")) }
        if case .object(let object) = statement { names += object.names }
        return names.isEmpty ? [nil] : names.map { Optional($0) }
    }
}
