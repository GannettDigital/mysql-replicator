import Foundation
import ReplicatorCapture
import ReplicatorCodec
import ReplicatorLogging

public struct DryRunRecord: Encodable {
    public let kind = "dry_run_transaction"
    public let gtid: String
    public let position: BinlogCoordinate
    public let executor: String
    public let operations: [String: Int]
    public let tables: [String]
    public let reason: String?
}

public struct DryRunSummary: Encodable {
    public let kind = "dry_run_summary"
    public let mode: String
    public var status = "complete"
    public var transactionsInspected = 0
    public var rowsInspected = 0
    public var ddlInspected = 0
    public var transactionsFiltered = 0
    public var inspectedGTIDs = ""
    public var lastInspectedPosition: BinlogCoordinate?
    public var pendingGTID: String?
    public var reason: String?
    public let unchecked = [
        "No target execution: SQL permissions, constraints, triggers, generated values, row matches, and server-generated schema metadata are not proved.",
        "DDL is discarded. Metadata is read again from the unchanged target. Later events can fail or use the old schema. Existing SQLite state is not read.",
        "No GTID assignment, BINLOG event, scratch object, writer lock, recovery journal, or applied checkpoint is written.",
        "SQL templates are inspected. Final bindings, JSON scratch expressions, batch sizes, and session commands are not executed or verified.",
        "skipErrors is not exercised because no target writes are issued. An error stops this preview.",
    ]
}

public struct DryRunFailure: Error {
    public let summary: DryRunSummary
}

public enum DryRun {
    public static func run(
        configuration c: ApplyConfiguration, offline: Bool, archive: ArchiveConfiguration? = nil,
        cancellation: CaptureCancellation = .init(), emit: @escaping (DryRunRecord) throws -> Void
    ) throws -> DryRunSummary {
        try c.validate(offline: offline)
        try require(
            offline || c.source.nonBlocking == true || c.source.stopAfterTransactions != nil
                || c.source.stopAfterGTIDs != nil,
            "live dry run requires source.stopAfterTransactions, source.stopAfterGTIDs, or source.nonBlocking=true")
        try require(
            !offline || (archive != nil && c.source.mode == "gtid"),
            "replay dry run requires archive settings and GTID positioning")
        let password = try PasswordConfiguration.resolve(
            password: c.target.password,
            environmentVariable: c.target.passwordEnvironment, endpoint: "target")
        let target = try TargetSession(configuration: c, password: password, metadataOnly: true)
        try target.preflightSettings()
        try target.nativeExclusion()
        let metadata: (TableName) throws -> ApplyTable? = { name in
            try target.tableExists(name) ? target.readSchema(database: name.database, name: name.table) : nil
        }
        let preview = try DryRunEngine(
            configuration: c, offline: offline, metadata: metadata,
            targetVersion: target.serverVersionID!, packetLimit: target.packetByteLimit, tokens: target.ddlTokens,
            writer: target.queries.writes, emit: emit)
        do {
            func event(_ record: LiveRecord) throws { try preview.recordFailure { try preview.event(record) } }
            func transaction(_ group: CompleteTransaction) throws {
                try preview.recordFailure { try preview.transaction(group) }
            }
            let resolver: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])? =
                c.replicationProfile.sourceContract.requiresHistoricalSchema
                ? { event, _ in
                    try preview.recordFailure {
                        try preview.tableMap(event).columns.map { try DMLColumnType($0).interpretation }
                    }
                } : nil
            if offline {
                let input = try ArchiveReplay(
                    configuration: archive!, source: c.source, contract: c.replicationProfile.sourceContract)
                try input.run(
                    configuration: c.source, cancellation: cancellation, retainRawBytes: true,
                    emitEvent: event, emitTransaction: transaction, resolveSchema: resolver,
                    timings: .init(), ignoreTable: { preview.filter.ignores(database: $0, table: $1) })
            } else {
                let sourcePassword = try PasswordConfiguration.resolve(
                    password: c.source.password,
                    environmentVariable: c.source.passwordEnvironment, endpoint: "source")
                _ = try LiveInspection.run(
                    configuration: c.source, password: sourcePassword, retainRawBytes: true,
                    cancellation: cancellation, emitEvent: event, emitTransaction: transaction,
                    resolveSchema: resolver, allowDDL: true,
                    ignoreTable: { preview.filter.ignores(database: $0, table: $1) },
                    sourceContract: c.replicationProfile.sourceContract)
            }
            return preview.summary
        } catch {
            var summary = preview.summary
            summary.status =
                preview.unresolved || error is DryRunUnresolved
                ? "unresolved" : (cancellation.isCancelled ? "cancelled" : "failed")
            // LiveInspection adds counters but retains the underlying reason.
            summary.reason = String(describing: error)
            throw DryRunFailure(summary: summary)
        }
    }
}

/// Serial preview: DDL invalidates metadata before the next table-map decode.
/// The only write capability is a discard connection. No apply state is opened.
final class DryRunEngine {
    let configuration: ApplyConfiguration
    let schema = SchemaMetadataCache()
    let metadata: (TableName) throws -> ApplyTable?
    let filter: TableFilter
    let targetVersion: Int
    let packetLimit: Int
    let tokens: (QueryControl) throws -> [DDLToken]
    let emit: (DryRunRecord) throws -> Void
    let writer: any TargetQueryConnection
    private(set) var summary: DryRunSummary
    private var inspected: GTIDSet
    private(set) var unresolved = false
    func recordFailure<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() } catch {
            if error is DryRunUnresolved { unresolved = true }
            throw error
        }
    }
    private var capture: BinlogGroupCapture
    private var planning: DMLPlanningCache
    init(
        configuration c: ApplyConfiguration, offline: Bool, metadata: @escaping (TableName) throws -> ApplyTable?,
        targetVersion: Int, packetLimit: Int, tokens: @escaping (QueryControl) throws -> [DDLToken],
        writer: any TargetQueryConnection = DiscardTargetQueryConnection(),
        emit: @escaping (DryRunRecord) throws -> Void
    ) throws {
        inspected = try GTIDSet("")
        configuration = c
        self.metadata = metadata
        filter = try TableFilter(
            c.replicateWildIgnoreTable ?? [], including: c.replicateWildDoTable ?? [],
            lowerCaseTableNames: c.source.tableNameCaseSetting)
        self.targetVersion = targetVersion
        self.packetLimit = packetLimit
        self.tokens = tokens
        self.emit = emit
        self.writer = writer
        summary = DryRunSummary(mode: offline ? "replay" : "run")
        capture = BinlogGroupCapture(
            maximumRawBytes: Int(c.source.maximumTransactionBytes ?? BinlogLimits.defaultTransactionBytes))
        planning = try DMLPlanningCache(
            compatibility: c.compatibilityPolicy,
            legacyMetadata: c.replicationProfile.sourceContract.requiresHistoricalSchema)
    }
    func tableMap(_ event: DecodedEvent) throws -> ApplyTable {
        guard let database = event.database, let name = event.table else {
            throw ApplyError("preview table-map has no name")
        }
        guard let table = try schema.table(.init(database: database, table: name), read: metadata) else {
            throw DryRunUnresolved(
                "dry-run target table is absent: \(database).\(name); discarded DDL does not change the target")
        }
        try table.validate()
        try configuration.replicationProfile.targetContract.validateSchemaFeatures(table)
        try planning.insert(table)
        return try planning.validate(event)
    }
    func event(_ record: LiveRecord) throws {
        capture.append(record)
        guard record.kind == "event", let event = record.event else { return }
        if case .gtid(let value) = event.control { summary.pendingGTID = value.canonical }
        if event.eventType == 19 && !event.replicationFiltered { _ = try tableMap(event) }
    }
    func transaction(_ group: CompleteTransaction) throws {
        guard let gtid = group.gtid else { throw ApplyError("dry run requires a named source GTID") }
        summary.pendingGTID = gtid.canonical
        defer { capture.resetGroup() }
        if configuration.target.preserveSourceGTIDs {
            try SourceGTIDExecution.validate(gtid, targetVersion: targetVersion)
        }
        let record: DryRunRecord
        if group.outcome == .statement {
            guard group.events.count == 2, case .query(let query) = group.events[1].control else {
                throw ApplyError("invalid preview DDL group")
            }
            let view = try LoggedDDL.parsingView(query, targetVersion: targetVersion)
            let words = try tokens(view)
            let skip = try (configuration.ddlPolicy ?? DDLPolicy()).skippedQuery(
                query,
                profile: configuration.replicationProfile, tokens: words, targetVersion: targetVersion)
            if try skip != nil || filter.ignores(view, tokens: words) {
                record = .init(
                    gtid: gtid.canonical, position: group.end, executor: "skip", operations: [:], tables: [],
                    reason: skip?.reason ?? "table-filter")
                summary.transactionsFiltered += 1
            } else {
                // Validate source syntax and select configured compatibility edits.
                _ = try DDLStatement.from(
                    group, profile: configuration.replicationProfile, tokens: words,
                    lowerCaseTableNames: configuration.source.tableNameCaseSetting, targetVersion: targetVersion)
                let context = try QuerySessionContext(query: view)
                var parser = try DDLParser(query: view, tokens: words)
                parser.nativeRules = NativeReplicationRules(profile: configuration.replicationProfile)
                parser.engine = configuration.replicationProfile.targetContract.engine
                parser.targetVersion = configuration.replicationProfile.targetContract.versionPrefix
                parser.lowerCaseTableNames = configuration.source.tableNameCaseSetting
                parser.compatibility = configuration.compatibilityPolicy
                parser.defaultUTF8MB4Collation = context.defaultUTF8MB4Collation
                let statement = words.isEmpty ? DDLStatement.versionCommentNoop : try parser.parse()
                // Clear related tables as well as direct DDL targets. No new
                // schema is invented when writes are discarded.
                schema.invalidateAll()
                // This is a parsed DDL preview, not a native scratch-table probe.
                let bytes = parser.translatedBytes(query.sql)
                _ = try writer.execute(
                    String(decoding: bytes, as: UTF8.self), binds: [], textProtocol: true, rawSQL: bytes)
                planning = try DMLPlanningCache(
                    schema.tables, compatibility: configuration.compatibilityPolicy,
                    legacyMetadata: configuration.replicationProfile.sourceContract.requiresHistoricalSchema)
                record = .init(
                    gtid: gtid.canonical, position: group.end, executor: "sql", operations: ["ddl": 1],
                    tables: statement.name.map { ["\($0.database).\($0.table)"] } ?? [],
                    reason: "DDL discarded; metadata will be read from the unchanged target")
                summary.ddlInspected += 1
            }
        } else {
            let mutations = try DMLPlan.make(
                group, tables: planning.tables, transactional: configuration.replicationProfile.transactional)
            var executor = mutations.isEmpty ? "skip" : "sql"
            var reason: String?
            if configuration.target.transport == .binlog && !mutations.isEmpty {
                let selection = DMLSQLReason.select(
                    group, mutations: mutations, compatibility: configuration.compatibilityPolicy)
                reason = selection?.rawValue
                if selection == nil {
                    let program = try capture.prepare(
                        group, mutations: mutations, maximumPacketBytes: packetLimit,
                        transactional: configuration.replicationProfile.transactional,
                        preserveSourceGTIDs: configuration.target.preserveSourceGTIDs)
                    for request in [program.format] + program.statements {
                        _ = try writer.execute(request.sql(), binds: [], textProtocol: true, rawSQL: nil)
                    }
                    executor = "binlog"
                }
            }
            if executor == "sql" {
                var plans: [SQLNameKey: DMLSQLPlan] = [:]
                for mutation in mutations {
                    let identity = mutation.table.identity
                    let plan = try plans[identity] ?? DMLSQLPlan(mutation.table)
                    plans[identity] = plan
                    // Inspect the common SQL template. Actual bindings, native
                    // JSON scratch expressions and batch sizes need execution.
                    let sql: String
                    switch mutation.row.operation {
                    case "insert": sql = plan.insert
                    case "update": sql = plan.update
                    case "delete": sql = plan.delete
                    default: throw ApplyError("unsupported preview row operation")
                    }
                    _ = try writer.execute(sql, binds: [], textProtocol: false, rawSQL: nil)
                }
            }
            record = .init(
                gtid: gtid.canonical, position: group.end, executor: executor,
                operations: Dictionary(grouping: mutations, by: { $0.row.operation }).mapValues(\.count),
                tables: Set(mutations.map { "\($0.table.database).\($0.table.table)" }).sorted(), reason: reason)
            summary.rowsInspected += mutations.count
            if mutations.isEmpty { summary.transactionsFiltered += 1 }
        }
        try emit(record)
        try inspected.include(gtid)
        summary.inspectedGTIDs = inspected.canonical
        summary.lastInspectedPosition = group.end
        summary.transactionsInspected += 1
        summary.pendingGTID = nil
    }
}
