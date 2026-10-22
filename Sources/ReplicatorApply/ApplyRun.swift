import Foundation
import ReplicatorCapture
import ReplicatorCodec
import ReplicatorLogging

public struct ApplySummary: Encodable {
    public let kind = "apply_summary"
    public let lifecycle: String
    public let transactionsApplied: Int
    public let rowsApplied: Int
    public let ddlApplied: Int
    public let appliedPosition: BinlogCoordinate?
    public let appliedGTIDSet: String
    public let pendingGTID: String?
    public let stateDirectory: String
    public let stageTimings: [String: StageTimings.Sample]?
    public let pipeline: PipelineSnapshot?
    public let sourceReconnectEnabled: Bool
    public let sourceReconnectAttempts: Int
    public let sourceReconnectReason: String?
    public let targetReconnectEnabled: Bool
    public let targetReconnectAttempts: Int
    public let targetReconnectReason: String?
    public let targetFailure: TargetFailureDiagnostic?
    public let drainRequested: Bool
    public var stopReason: String? = nil
    public var activeBatchTransactions: Int = 0
    public var skippedTransactionsByCode: [String: Int] = [:]
    public var sourceFailurePosition: BinlogCoordinate? = nil
    public var pendingTransactions: [PendingTransactionPosition] = []
    public var pendingTransactionCount: Int = 0
    public var recovery: RecoveryAdvice? = nil
    public var estimate: ProgressEstimate? = nil
    public var activity: RunActivitySnapshot? = nil
    public var counters: ApplyCounters? = nil
    public var tableStatistics: TableStatisticsSummary? = nil
    public var applyQueue: ApplyQueueSnapshot? = nil
    // Crash recovery / uncertain target replay remains unsupported.
    public let automaticRecovery = false
}
public struct ApplyRunError: Error, CustomStringConvertible {
    public let reason: String
    public let progress: ApplySummary
    public var code: ApplyErrorCode? = nil
    public var supportBundle: SupportBundle.AutomaticResult? = nil
    public var description: String { reason }
}
public enum ApplyRun {
    // Only capture-loop cancellation at a complete boundary is a clean stop.
    // An interrupted apply or an unrelated error retains fail-stop semantics.
    static func canStopCleanly(_ error: Error, pendingGTID: String?) -> Bool {
        guard let live = error as? LiveInspectionError else { return false }
        return live.isCancellation && live.summary.pendingTransactionStart == nil && pendingGTID == nil
    }

    /// Safe source/target transport failures reconnect from durable applied progress.
    /// Interrupted processes and uncertain target outcomes are never retried.
    public static func run(
        configuration: ApplyConfiguration, sourcePassword: String, targetPassword: String,
        initialize: Bool = false, cancellation: CaptureCancellation = .init(), drain: CaptureCancellation = .init(),
        archive: ArchiveReplay? = nil, control: RunControl? = nil,
        emitProgress: @escaping (ApplySummary) throws -> Void = { _ in }
    ) throws -> ApplySummary {
        try configuration.validate(offline: archive != nil)
        if archive != nil {
            try require(configuration.source.mode == "gtid", "offline replay requires GTID positioning")
        }
        let profile = configuration.replicationProfile
        ApplicationLog.logger.info(
            "Start replication",
            metadata: [
                "mode": .string(archive == nil ? "run" : "replay"), "profile": .string(profile.rawValue),
                "transport": .string(configuration.target.transport.rawValue),
            ])
        let legacyMetadata = profile.sourceContract.requiresHistoricalSchema
        let filter = try TableFilter(
            configuration.replicateWildIgnoreTable ?? [], including: configuration.replicateWildDoTable ?? [],
            lowerCaseTableNames: configuration.source.tableNameCaseSetting)
        let activity = control?.activity ?? RunActivity()
        activity.begin(.coordinator, "starting")
        defer { activity.end(.coordinator) }
        let timings = StageTimings()
        let producerTimings = StageTimings()
        let targetTimings = StageTimings()
        var pipeline = ApplyPipeline(
            maximumItemBytes: configuration.source.transactionLimits.retainedBytes
                + Int(configuration.source.transactionLimits.wireBytes) + 65536)
        var retry = SourceRetryState(policy: configuration.reconnectPolicy)
        var reconnectReason: String?
        var targetRetry = SourceRetryState(policy: configuration.targetReconnectPolicy)
        var targetReason: String?
        var recoveryAdvice: RecoveryAdvice?
        var sourceFailurePosition: BinlogCoordinate?
        var targetFailure: TargetFailureDiagnostic?
        var consumerPending = false
        var limits = try StopConditions(
            transactions: configuration.source.stopAfterTransactions, gtids: configuration.source.stopAfterGTIDs)
        var stopReason: String?
        var finalResult: ApplySummary?
        var activeBatchTransactions = 0
        var executionQueue: DMLExecutor?
        let state = try ApplicationLog.measure("Open replication state", metadata: ["phase": "state"]) {
            try StateStore(configuration: configuration, initialize: initialize, timings: timings)
        }
        control?.setTableStatistics(state.tableStatistics)
        activity.resetPositions(to: state.applied)
        let statistics = configuration.statistics ?? StatisticsPolicy()
        let estimator = ProgressEstimator(window: statistics.rateWindowSeconds)
        let monitor = archive == nil ? SourceMonitor() : nil
        monitor?.start(
            source: configuration.source, password: sourcePassword, contract: profile.sourceContract,
            interval: statistics.sourcePollIntervalSeconds)
        defer { monitor?.stop() }
        var savedObservation: Double?
        func estimate(_ lifecycle: String) -> ProgressEstimate {
            let sample = monitor?.snapshot()
            let observation = sample?.observation
            let goal = archive != nil ? (limits.stopAfterGTIDs ?? archive?.availableGTIDs) : observation?.executedGTIDs
            var value = estimator.update(
                now: ProcessInfo.processInfo.systemUptime, transactions: state.transactions,
                bytes: state.counters.processedBinlogBytes,
                completed: state.gtids, goal: goal, replay: archive != nil, lifecycle: lifecycle,
                observation: observation)
            value.sourceObservation = observation
            value.sourceObservationStaleAfterSeconds = statistics.sourcePollIntervalSeconds * 2
            value.monitoringError = sample?.error
            if let observation {
                let age = max(0, Date().timeIntervalSince1970 - observation.observedAt)
                value.sourceObservationAgeSeconds = age
                value.sourceObservationStale =
                    age > Double(statistics.sourcePollIntervalSeconds * 2) || sample?.error != nil
                if value.sourceObservationStale {
                    value.provisional = true
                    if value.status != "paused" { value.status = "staleSourceSample" }
                }
                if let applied = state.applied {
                    value.remainingBinlogBytes = observation.bytesRemaining(after: applied)
                }
            }
            return value
        }
        func finalTimings() -> [String: StageTimings.Sample] {
            let merged = StageTimings()
            merged.merge(timings.snapshot)
            merged.merge(producerTimings.snapshot)
            merged.merge(targetTimings.snapshot)
            return merged.snapshot
        }
        func summary(_ lifecycle: String) -> ApplySummary {
            activity.checkpoint(transactions: state.transactions)
            return ApplySummary(
                lifecycle: lifecycle, transactionsApplied: state.transactions, rowsApplied: state.rows,
                ddlApplied: state.ddlApplied,
                appliedPosition: state.applied, appliedGTIDSet: state.gtids, pendingGTID: state.pendingGTID,
                stateDirectory: state.directory.path,
                stageTimings: ["RUNNING", "DRAINING"].contains(lifecycle) ? nil : finalTimings(),
                pipeline: lifecycle == "RUNNING" ? nil : pipeline.queue.snapshot,
                sourceReconnectEnabled: archive == nil && configuration.reconnectPolicy.enabled,
                sourceReconnectAttempts: retry.attempts, sourceReconnectReason: reconnectReason,
                targetReconnectEnabled: configuration.targetReconnectPolicy.enabled,
                targetReconnectAttempts: targetRetry.attempts,
                targetReconnectReason: targetReason, targetFailure: targetFailure, drainRequested: drain.isCancelled,
                stopReason: stopReason, activeBatchTransactions: activeBatchTransactions,
                skippedTransactionsByCode: state.skippedTransactionsByCode,
                sourceFailurePosition: sourceFailurePosition,
                pendingTransactions: state.pendingTransactions, pendingTransactionCount: state.pendingTransactionCount,
                recovery: recoveryAdvice, estimate: estimate(lifecycle),
                counters: state.counters, tableStatistics: state.tableStatistics?.summary,
                applyQueue: executionQueue?.snapshot
            ).refreshingActivity(from: activity)
        }
        var lastLogLifecycle: String?
        var lastLogTime: UInt64 = 0
        func report(_ value: ApplySummary) throws {
            if ApplicationLog.logger.logLevel <= .info {
                let now = DispatchTime.now().uptimeNanoseconds
                if lastLogLifecycle != value.lifecycle || now - lastLogTime >= 5_000_000_000 {
                    ApplicationLog.logger.info(
                        "Replication status",
                        metadata: [
                            "lifecycle": .string(value.lifecycle),
                            "transactions": .string(String(value.transactionsApplied)),
                            "rows": .string(String(value.rowsApplied)),
                            "file": .string(value.appliedPosition?.file ?? ""),
                            "position": .string(value.appliedPosition.map { String($0.position) } ?? ""),
                        ])
                    lastLogLifecycle = value.lifecycle
                    lastLogTime = now
                }
            }
            if let observation = value.estimate?.sourceObservation, observation.observedAt != savedObservation {
                try state.saveSourceObservation(observation)
                savedObservation = observation.observedAt
            }
            control?.publish(value)
            try emitProgress(value)
        }
        func stoppedResult() -> ApplySummary {
            if drain.isCancelled { stopReason = "drainRequested" }
            let result = summary("STOPPED")
            ApplicationLog.logger.info(
                "Replication stopped",
                metadata: [
                    "lifecycle": "STOPPED", "transactions": .string(String(state.transactions)),
                    "reasonCode": .string(stopReason ?? "completed"),
                ])
            finalResult = result
            return result
        }
        defer { control?.finish(finalResult ?? summary("BLOCKED")) }
        func progress() throws {
            // Include snapshot construction, JSON encoding and the synchronous
            // output callback so stdout backpressure is visible in final timings.
            try timings.measure("progress.emit") {
                try report(summary("RUNNING"))
            }
        }
        let initialTransactions = state.transactions
        var started = false
        var replayReadinessRejected = false
        do {
            control?.publish(summary("STARTING"))
            try control?.start(directory: state.directory)
            while true {
                replayReadinessRejected = false
                do {
                    if archive != nil && !started && (cancellation.isCancelled || drain.isCancelled) {
                        try state.archiveValidationStopped()
                        return stoppedResult()
                    }
                    let target = try ApplicationLog.measure("Connect to target", metadata: ["phase": "target_connect"])
                    {
                        try activity.measure(.target, "connecting") {
                            try TargetSession(
                                configuration: configuration, password: targetPassword, timings: targetTimings,
                                activity: activity, tableStatistics: state.tableStatistics)
                        }
                    }
                    defer { try? target.unlock() }
                    if let archive {
                        do {
                            try ApplicationLog.measure(
                                "Validate target readiness", metadata: ["phase": "target_validate"]
                            ) {
                                try TargetReadiness.checkForReplay(target)
                                if let savedUUID = state.targetUUID {
                                    try require(
                                        target.targetUUID == savedUUID, "target UUID differs from saved checkpoint")
                                }
                            }
                        } catch {
                            // These probes issue only reads and session settings.
                            // They run before archive reads or target mutations.
                            replayReadinessRejected = !started
                            targetFailure = TargetFailureDiagnostic(
                                reason: String(describing: error), statement: .init(), rows: [],
                                ddlGTID: nil, ddlSQL: nil, targetSQL: (error as? ApplyError)?.targetSQL)
                            throw error
                        }
                        do {
                            // Retain complete validation before writer ownership,
                            // scratch setup, GTID repair, or application writes.
                            // Reconnect reuses ArchiveReplay's in-memory result.
                            try activity.measure(.coordinator, "archiveValidation") {
                                try archive.validate(
                                    baseline: state.gtids, stopAfterGTIDs: limits.stopAfterGTIDs,
                                    resumeFrom: state.applied,
                                    persistence: state.archiveValidationPersistence(),
                                    isCancelled: { cancellation.isCancelled || drain.isCancelled })
                            }
                        } catch is CaptureCancelled {
                            try state.archiveValidationStopped()
                            return stoppedResult()
                        }
                    }
                    try ApplicationLog.measure("Check target", metadata: ["phase": "target_setup"]) {
                        try activity.measure(.coordinator, "targetSetup") { try target.preflight() }
                    }
                    try state.bindTargetIdentity(target.targetUUID!)
                    for identity in try state.pendingGTIDMarkers() {
                        try SourceGTIDExecution.validate(identity, targetVersion: target.serverVersionID ?? 0)
                        if try target.scalar(
                            "SELECT GTID_SUBSET(?,@@GLOBAL.gtid_executed) AS v", [.init(string: identity.canonical)])
                            == "0"
                        {
                            try target.emptySourceGTID(identity)
                        }
                        try state.completeGTIDMarker(identity)
                    }
                    for table in state.currentSchemas
                    where !filter.ignores(database: table.database, table: table.table) {
                        try require(
                            try target.readSchema(database: table.database, name: table.table) == table,
                            "target schema differs from saved checkpoint")
                        // DDL barriers must see every validated saved table, including
                        // tables with no row event since resume (e.g. DROP DATABASE).
                        target.discovered[table.identity] = table
                        state.tableStatistics?.schema(table)
                    }
                    try state.running()
                    started = true
                    activity.end(.coordinator)
                    activity.begin(.coordinator, "running")
                    targetReason = nil
                    try progress()
                    let executor = DMLExecutor(
                        capacity: configuration.batchPolicy.overlapPreparation
                            ? configuration.batchPolicy.maximumPreparedBatches : 1)
                    executionQueue = executor
                    var binlogCapture = BinlogGroupCapture(
                        maximumRawBytes: Int(
                            configuration.source.maximumTransactionBytes ?? BinlogLimits.defaultTransactionBytes))
                    let packetLimit = target.packetByteLimit
                    let byteLimit = target.insertByteLimit
                    let executionStop = CaptureCancellation(parent: cancellation)
                    func checkSourceFailure() throws {
                        try pipeline.queue.checkFailure(
                            allowSourceReconnect: configuration.reconnectPolicy.enabled, allowDrain: true)
                    }
                    var planningCache = try DMLPlanningCache(
                        target.discovered, compatibility: configuration.compatibilityPolicy,
                        legacyMetadata: legacyMetadata)
                    func finishOneExecution() throws {
                        guard executor.active else { return }
                        do {
                            guard
                                let outcome = activity.measure(
                                    .coordinator, "targetCompletionWait",
                                    {
                                        timings.measure("apply.execution_wait", { executor.join() })
                                    })
                            else {
                                throw ApplyError("prepared batch was not executed after an earlier failure")
                            }
                            var outcomes = [outcome]
                            while outcomes.last!.failure == nil && executor.ready {
                                guard let next = executor.join() else {
                                    throw ApplyError("missing prepared batch outcome")
                                }
                                outcomes.append(next)
                            }
                            if let diagnostic = outcomes.last!.diagnostic { targetFailure = diagnostic }
                            try DMLExecution.Outcome.record(outcomes, in: state)
                            activeBatchTransactions -= outcomes.reduce(0) { $0 + $1.acknowledged.count }
                            try progress()
                        } catch {
                            // A checkpoint failure can race a later, already-durable
                            // batch. Stop and join it; retain all outstanding intents.
                            executionStop.cancel()
                            executor.cancelAndWait()
                            activeBatchTransactions = 0
                            throw error
                        }
                    }
                    func finishExecution() throws {
                        while executor.active { try finishOneExecution() }
                    }
                    // Always join before target destruction, diagnostics or a journal
                    // error path. Main-thread failures stop further target statements.
                    defer {
                        executionStop.cancel()
                        executor.cancelAndWait()
                    }
                    // Collect up to half the durable queue per preparation window,
                    // leaving room to journal ahead of the currently executing window.
                    // Row, byte, age, table and DDL boundaries still bound collection.
                    let transactionsPerBatch = configuration.batchPolicy.maximumTransactions
                    var preparationPolicy = configuration.batchPolicy
                    preparationPolicy.maximumTransactions *= max(1, executor.capacity / 2)
                    let batch = DMLBatch(
                        policy: preparationPolicy,
                        onFlush: { reason in timings.measure("apply.batch.flush." + reason) {} }
                    ) { groups in
                        let large = groups.contains { $0.wireBytes > configuration.batchPolicy.maximumWireBytes }
                        if large { try finishExecution() }
                        let batches = stride(from: 0, to: groups.count, by: transactionsPerBatch).map {
                            Array(groups[$0..<min($0 + transactionsPerBatch, groups.count)])
                        }
                        // Reap published completions together, sharing one SQLite commit.
                        if executor.ready { try finishOneExecution() }
                        while executor.available < batches.count { try finishOneExecution() }
                        try checkSourceFailure()
                        try activity.measure(.coordinator, "savingPreparedBatches") {
                            try timings.measure("apply.batch.prepare") { try state.beginBatches(batches) }
                        }
                        if let last = groups.last { activity.didPrepare(last.group.end) }
                        activeBatchTransactions += groups.count
                        control?.publish(summary("RUNNING"))
                        for prepared in batches {
                            executor.start {
                                activity.begin(.target, "executingBatch")
                                defer { activity.end(.target) }
                                return targetTimings.measure("apply.batch.execute") {
                                    target.execute(
                                        prepared, cancellation: executionStop, maximumInsertBytes: byteLimit,
                                        checkSourceFailure: checkSourceFailure)
                                }
                            }
                        }
                        if large || !configuration.batchPolicy.overlapPreparation { try finishExecution() }
                    }
                    func barrier(_ reason: String = "barrier") throws {
                        try batch.flush(reason: reason)
                        try finishExecution()
                    }
                    func maintainExecution() throws {
                        // Successful tickets may wait until the next preparation window
                        // or barrier. Failure is handled promptly, without issuing more SQL.
                        if executor.failed { try finishExecution() }
                        if !executor.active {
                            try target.checkConnection()
                            try target.releaseExpiredLock()
                        }
                    }
                    func event(_ record: LiveRecord) throws {
                        if let event = record.event { state.tableStatistics?.observe(event) }
                        if !cancellation.isCancelled { try batch.flushIfExpired() }
                        try maintainExecution()
                        try timings.measure("relay.append") { try state.append(record) }
                        if configuration.target.transport == .binlog { binlogCapture.append(record) }
                        if let decoded = record.event {
                            if case .gtid = decoded.control { consumerPending = true }
                            if decoded.eventType == 19 && !decoded.replicationFiltered {
                                guard let database = decoded.database, let name = decoded.table else {
                                    throw ApplyError("missing table-map identity")
                                }
                                let identity = SQLNameKey.table(database, name)
                                let table: ApplyTable
                                if planningCache.tables[identity] != nil {
                                    ApplicationLog.logger.debug(
                                        "Use cached table map",
                                        metadata: [
                                            "cache": "hit", "database": .string(database), "table": .string(name),
                                        ])
                                    table = try state.profile("target.discover") { try planningCache.validate(decoded) }
                                } else {
                                    try barrier()
                                    table = try target.discover(decoded)
                                    state.tableStatistics?.schema(table)
                                    try planningCache.insert(table)
                                    _ = try planningCache.validate(decoded)
                                }
                                guard let offset = UInt64(decoded.offset) else {
                                    throw ApplyError("invalid table-map coordinate")
                                }
                                try state.schema(
                                    table, event: decoded,
                                    coordinate: BinlogCoordinate(file: record.file, position: offset))
                            }
                        }
                    }
                    func transaction(_ group: CompleteTransaction) throws {
                        defer {
                            consumerPending = false
                            binlogCapture.resetGroup()
                        }
                        if group.outcome == .statement {
                            ApplicationLog.logger.info(
                                "Prepare source DDL",
                                metadata: ["phase": "ddl", "gtid": .string(group.gtid?.canonical ?? "")])
                            try barrier()
                            target.statementTrace = .init()
                            try state.begin(group)
                            activity.didPrepare(group.end)
                            control?.publish(summary("RUNNING"))
                            var hasDDLIntent = false
                            do {
                                try target.unlock()
                                try target.checkSourceGTID(group.gtid!)
                                try require(group.events.count == 2, "invalid standalone DDL group")
                                guard case .query(let query) = group.events[1].control else {
                                    throw ApplyError("missing DDL query")
                                }
                                guard let version = target.serverVersionID else {
                                    throw ApplyError("target version is unavailable")
                                }
                                let view = try LoggedDDL.parsingView(query, targetVersion: version)
                                let ddlTokens = try target.ddlTokens(view)
                                if let skipped = try (configuration.ddlPolicy ?? DDLPolicy()).skippedQuery(
                                    query, profile: profile, tokens: ddlTokens, targetVersion: version)
                                {
                                    try target.emptySourceGTID(group.gtid!)
                                    try state.complete(group, rowCount: 0, filtered: true, skippedDDL: skipped)
                                    try progress()
                                    return
                                }
                                if try filter.ignores(view, tokens: ddlTokens) {
                                    try target.emptySourceGTID(group.gtid!)
                                    try state.complete(group, rowCount: 0, filtered: true)
                                    try progress()
                                    return
                                }
                                let statement = try DDLStatement.from(
                                    group, profile: profile, tokens: ddlTokens,
                                    lowerCaseTableNames: configuration.source.tableNameCaseSetting,
                                    targetVersion: version)
                                var plan = try target.prepareDDL(
                                    statement, query: query, timestamp: UInt64(group.events[1].timestamp),
                                    tokens: ddlTokens)
                                if configuration.target.preserveSourceGTIDs && !profile.transactional {
                                    let databases =
                                        [
                                            plan.database?.name, plan.statement.name?.database, plan.before?.database,
                                            plan.after?.database,
                                        ].compactMap { $0 }
                                        + plan.additional.flatMap {
                                            [$0.before?.database, $0.after?.database].compactMap { $0 }
                                        }
                                    try require(
                                        !databases.contains { $0.lowercased() == "_mysql_replicator_gtid" },
                                        "source DDL conflicts with the reserved GTID scratch database")
                                }
                                if view.sql != query.sql { plan.compatibilityRules.append(LoggedDDL.commentRule) }
                                state.tableStatistics?.planDDL(plan)
                                try state.ddlIntent(plan, event: group.events[1], coordinate: group.start)
                                hasDDLIntent = true
                                try require(!cancellation.isCancelled, "apply cancelled")
                                try checkSourceFailure()
                                try ApplicationLog.measure(
                                    "Apply source DDL",
                                    metadata: ["phase": "ddl", "gtid": .string(group.gtid!.canonical)]
                                ) {
                                    try target.sourceStatement(
                                        group.gtid!, requiresCommit: plan.statement == .versionCommentNoop
                                    ) { try target.applyDDL(&plan) }
                                }
                                planningCache = try DMLPlanningCache(
                                    target.discovered, compatibility: configuration.compatibilityPolicy,
                                    legacyMetadata: legacyMetadata)
                                try state.complete(group, rowCount: 0, ddl: plan)
                                ApplicationLog.logger.info(
                                    "DDL checkpoint saved", metadata: ["gtid": .string(group.gtid!.canonical)])
                                try progress()
                                return
                            } catch {
                                if !hasDDLIntent { state.tableStatistics?.failure(planning: true) }
                                if !hasDDLIntent && target.statementTrace.phase == .notIssued
                                    && !cancellation.isCancelled,
                                    let skip = configuration.skipErrorPolicy.match(error, at: .beforeWrites)
                                {
                                    try target.emptySourceGTID(group.gtid!)
                                    try state.skipUnwritten(group, error: skip)
                                    try progress()
                                    return
                                }
                                let failedQuery = group.events.compactMap { event -> QueryControl? in
                                    if case .query(let query) = event.control { return query }
                                    return nil
                                }.first
                                let diagnostic = TargetFailureDiagnostic(
                                    reason: String(describing: error), statement: target.statementTrace,
                                    rows: [], ddlGTID: state.pendingGTID,
                                    ddlSQL: failedQuery.map { String(decoding: $0.sql, as: UTF8.self) },
                                    ddlContext: failedQuery.flatMap { DDLQueryContextDiagnostic(query: $0) },
                                    targetSQL: (error as? ApplyError)?.targetSQL)
                                targetFailure = diagnostic
                                try state.recordTargetFailure(diagnostic)
                                if error is TargetConnectionFailure && target.statementTrace.phase == .notIssued {
                                    try state.discardUnwrittenPending()
                                }
                                throw error
                            }
                        }
                        let mutations: [Mutation]
                        var binlog: BinlogEventProgram?
                        var sqlReason: DMLSQLReason?
                        do {
                            mutations = try state.profile("dml.plan") {
                                try DMLPlan.make(
                                    group, tables: planningCache.tables, transactional: profile.transactional)
                            }
                            state.tableStatistics?.plan(mutations)
                            if configuration.target.transport == .binlog && !mutations.isEmpty {
                                sqlReason = DMLSQLReason.select(
                                    group, mutations: mutations, compatibility: configuration.compatibilityPolicy)
                                if sqlReason == nil {
                                    binlog = try timings.measure("apply.binlog.prepare") {
                                        try binlogCapture.prepare(
                                            group, mutations: mutations,
                                            maximumPacketBytes: packetLimit, transactional: profile.transactional,
                                            preserveSourceGTIDs: configuration.target.preserveSourceGTIDs)
                                    }
                                }
                                ApplicationLog.logger.debug(
                                    "Select DML transport",
                                    metadata: [
                                        "transport": .string(sqlReason == nil ? "binlog" : "sql"),
                                        "reasonCode": .string(sqlReason?.rawValue ?? "compatible"),
                                        "gtid": .string(group.gtid?.canonical ?? ""),
                                    ])
                            }
                        } catch {
                            state.tableStatistics?.failure(planning: true)
                            try barrier()
                            // Keep rejected, unwritten groups explicitly skippable.
                            try state.begin(group)
                            activity.didPrepare(group.end)
                            if !cancellation.isCancelled,
                                let skip = configuration.skipErrorPolicy.match(error, at: .beforeWrites)
                            {
                                try target.emptySourceGTID(group.gtid!)
                                try state.skipUnwritten(group, error: skip)
                                try progress()
                                return
                            }
                            throw error
                        }
                        if mutations.isEmpty {
                            try barrier()
                            try target.unlock()
                            try state.begin(group)
                            activity.didPrepare(group.end)
                            try target.checkSourceGTID(group.gtid!)
                            try target.emptySourceGTID(group.gtid!, rolledBack: group.outcome == .rolledBack)
                            try state.complete(group, rowCount: 0, filtered: true)
                            try progress()
                            return
                        }
                        try batch.append(
                            PreparedDMLGroup(
                                group: group, mutations: mutations, relayEnd: state.relayLength, binlog: binlog,
                                sqlReason: sqlReason))
                    }
                    while true {
                        if drain.isCancelled {
                            try report(summary("DRAINING"))
                            try state.discardUnappliedCapture()
                            activity.resetPositions(to: state.applied)
                            break
                        }
                        if let reason = limits.reason(
                            transactions: state.transactions - initialTransactions, executed: try GTIDSet(state.gtids))
                        {
                            stopReason =
                                reason == "gtidsSatisfied" && state.transactions == initialTransactions
                                ? "alreadySatisfied" : reason
                            break
                        }
                        let remaining = limits.stopAfterTransactions.map {
                            $0 - (state.transactions - initialTransactions)
                        }
                        var capture = try state.captureConfiguration(
                            configuration.source, remainingTransactions: remaining)
                        capture.stopAfterTransactions = remaining
                        capture.stopAfterGTIDs = limits.stopAfterGTIDs
                        let replayCheckpoint = state.applied
                        do {
                            activity.begin(.coordinator, "waitingForInput")
                            defer { activity.end(.coordinator) }
                            try pipeline.run(
                                cancellation: cancellation, producerTimings: producerTimings,
                                produce: { stop, send in
                                    activity.begin(
                                        .capture, archive == nil ? "sourceReadAndDecode" : "archiveReadAndDecode")
                                    defer { activity.end(.capture) }
                                    func sendEvent(_ record: LiveRecord) throws {
                                        if record.kind != "formatContext", let offset = UInt64(record.observedPosition)
                                        {
                                            activity.didRead(.init(file: record.file, position: offset))
                                        }
                                        try activity.measure(.capture, "queueWait") { try send(.event(record)) }
                                    }
                                    let resolver: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])? =
                                        legacyMetadata
                                        ? { event, _ in
                                            activity.begin(.capture, "schemaWait")
                                            defer { activity.end(.capture) }
                                            let request = ApplySchemaRequest(event)
                                            try send(.schema(request))
                                            return try producerTimings.measure("capture.schema_wait") {
                                                try request.wait(cancellation: stop)
                                            }
                                        } : nil
                                    if let archive {
                                        try archive.run(
                                            configuration: capture, cancellation: stop, retainRawBytes: true,
                                            resumeFrom: replayCheckpoint,
                                            emitEvent: sendEvent,
                                            emitTransaction: { group in
                                                activity.didRead(group.end)
                                                try activity.measure(.capture, "queueWait") {
                                                    try send(.transaction(group))
                                                }
                                            },
                                            resolveSchema: resolver, timings: producerTimings,
                                            ignoreTable: filter.isEmpty
                                                ? nil : { filter.ignores(database: $0, table: $1) },
                                            maximumCachedTables: configuration.schemaCacheTableLimit)
                                    } else {
                                        _ = try LiveInspection.run(
                                            configuration: capture, password: sourcePassword, retainRawBytes: true,
                                            cancellation: stop,
                                            emitEvent: sendEvent,
                                            emitTransaction: { group in
                                                activity.didRead(group.end)
                                                try activity.measure(.capture, "queueWait") {
                                                    try send(.transaction(group))
                                                }
                                            },
                                            resolveSchema: resolver,
                                            timings: producerTimings, onIdle: { try send(.idle) }, allowDDL: true,
                                            ignoreTable: filter.isEmpty
                                                ? nil : { filter.ignores(database: $0, table: $1) },
                                            sourceContract: profile.sourceContract,
                                            maximumCachedTables: configuration.schemaCacheTableLimit)
                                    }
                                },
                                consume: { message in
                                    activity.begin(.coordinator, "preparing")
                                    defer { activity.end(.coordinator) }
                                    if drain.isCancelled { throw ApplyDrainRequested() }
                                    if control?.reloadRequested == true { throw ApplyReloadRequested() }
                                    try timings.measure("apply.consume") {
                                        switch message {
                                        case .event(let record): try event(record)
                                        case .transaction(let group): try transaction(group)
                                        case .schema(let request):
                                            do {
                                                guard let db = request.event.database, let name = request.event.table
                                                else { throw ApplyError("missing schema identity") }
                                                let identity = SQLNameKey.table(db, name)
                                                if planningCache.tables[identity] == nil {
                                                    try barrier("schema")
                                                    let table = try target.discover(request.event)
                                                    state.tableStatistics?.schema(table)
                                                    try planningCache.insert(table)
                                                }
                                                let table = try planningCache.validate(request.event)
                                                request.complete(.success(table.columns.map(\.interpretation)))
                                            } catch {
                                                request.complete(.failure(error))
                                                throw error
                                            }
                                        case .idle:
                                            if !cancellation.isCancelled {
                                                try barrier("idle")
                                            } else {
                                                try finishExecution()
                                            }
                                            try target.unlock()
                                        }
                                    }
                                },
                                onWait: {
                                    if drain.isCancelled { throw ApplyDrainRequested() }
                                    if control?.reloadRequested == true { throw ApplyReloadRequested() }
                                    if !cancellation.isCancelled { try batch.flushIfExpired() }
                                    try maintainExecution()
                                }, timings: timings)
                            if drain.isCancelled {
                                try report(summary("DRAINING"))
                                try finishExecution()
                                try state.discardUnappliedCapture()
                                activity.resetPositions(to: state.applied)
                                batch.discard()
                            } else {
                                try barrier("end")
                            }  // Includes finite capture and clean EOF.
                            stopReason =
                                limits.reason(
                                    transactions: state.transactions - initialTransactions,
                                    executed: try GTIDSet(state.gtids)) ?? "endOfInput"
                            break
                        } catch {
                            let sourceInterrupted =
                                configuration.reconnectPolicy.enabled
                                && (error as? LiveInspectionError)?.isRetryableSourceFailure == true
                            let draining = error is ApplyDrainRequested
                            let reloading = error is ApplyReloadRequested
                            if !sourceInterrupted && !draining && !reloading { executionStop.cancel() }
                            if draining { try report(summary("DRAINING")) }
                            // Preserve acknowledged work even if preparation/decoding failed.
                            // Unwritten collected work is discarded; uncertain SQL is never retried.
                            do { try finishExecution() } catch let executionError {
                                if sourceInterrupted || draining || reloading { throw executionError }
                                throw ApplyError("\(error); target completion: \(executionError)")
                            }
                            if draining {
                                try state.discardUnappliedCapture()
                                activity.resetPositions(to: state.applied)
                                batch.discard()
                                consumerPending = false
                                break
                            }
                            if reloading, let control {
                                try state.discardUnappliedCapture()
                                activity.resetPositions(to: state.applied)
                                batch.discard()
                                consumerPending = false
                                try target.unlock()
                                do {
                                    let candidate = try control.candidate()
                                    try require(
                                        candidate.reason(
                                            transactions: state.transactions - initialTransactions,
                                            executed: try GTIDSet(state.gtids)) == nil,
                                        "new stop condition is already satisfied after issued work; it cannot rewind the target"
                                    )
                                    if let archive {
                                        try activity.measure(.coordinator, "archiveValidation") {
                                            try archive.validate(
                                                baseline: state.gtids, stopAfterGTIDs: candidate.stopAfterGTIDs)
                                        }
                                    }
                                    limits = candidate
                                    control.publish(summary("RUNNING"))
                                    control.acknowledge(.success(candidate))
                                } catch {
                                    control.publish(summary("RUNNING"))
                                    control.acknowledge(.failure(error))
                                }
                                pipeline = ApplyPipeline(
                                    maximumItemBytes: configuration.source.transactionLimits.retainedBytes
                                        + Int(configuration.source.transactionLimits.wireBytes) + 65536)
                                continue
                            }
                            if sourceInterrupted {
                                // The pipeline and receiver have joined. Only acknowledged,
                                // journaled target work may advance the restart boundary.
                                try state.discardUnappliedCapture()
                                activity.resetPositions(to: state.applied)
                                batch.discard()
                                consumerPending = false
                                try target.unlock()
                                if cancellation.isCancelled || drain.isCancelled { break }
                                if let reason = limits.reason(
                                    transactions: state.transactions - initialTransactions,
                                    executed: try GTIDSet(state.gtids))
                                {
                                    stopReason = reason
                                    break
                                }
                                reconnectReason = String(describing: error)
                                let delay: Int
                                do { delay = try retry.nextDelay(appliedTransactions: state.transactions) } catch {
                                    throw ApplyError("\(error); last source failure: \(reconnectReason!)")
                                }
                                try report(summary("RECONNECTING"))
                                ApplicationLog.logger.info(
                                    "Wait before source reconnect",
                                    metadata: [
                                        "phase": "source_reconnect", "attempt": .string(String(retry.attempts)),
                                        "delaySeconds": .string(String(delay)),
                                    ])
                                timings.measure("source.reconnect_wait") {
                                    activity.measure(.coordinator, "sourceReconnectWait") {
                                        SourceRetryState.wait(seconds: delay, cancellation: cancellation, drain: drain)
                                    }
                                }
                                if cancellation.isCancelled || drain.isCancelled { break }
                                pipeline = ApplyPipeline(
                                    maximumItemBytes: configuration.source.transactionLimits.retainedBytes
                                        + Int(configuration.source.transactionLimits.wireBytes) + 65536)
                                reconnectReason = nil
                                continue
                            }
                            guard !consumerPending && canStopCleanly(error, pendingGTID: state.pendingGTID) else {
                                throw error
                            }
                            break
                        }
                    }
                    try target.unlock()
                    if configuration.target.transport == .binlog { try target.resetSourceGTID() }
                    try state.stopped()
                    return stoppedResult()
                } catch {
                    guard error is TargetConnectionFailure, configuration.targetReconnectPolicy.enabled,
                        state.pendingGTID == nil
                    else { throw error }
                    // The old target session and its executor have been destroyed before
                    // reconnect. Only fully acknowledged groups can advance this boundary.
                    try state.discardUnappliedCapture()
                    activity.resetPositions(to: state.applied)
                    consumerPending = false
                    targetReason = String(describing: error)
                    if cancellation.isCancelled || drain.isCancelled {
                        if archive != nil && !started {
                            try state.archiveValidationStopped()
                        } else {
                            try require(state.targetUUID != nil, "target unavailable before identity was established")
                            try state.stopped()
                        }
                        return stoppedResult()
                    }
                    let delay: Int
                    do { delay = try targetRetry.nextDelay(appliedTransactions: state.transactions) } catch {
                        throw ApplyError("target reconnect attempts exhausted; last failure: \(targetReason!)")
                    }
                    try report(summary("TARGET_RECONNECTING"))
                    ApplicationLog.logger.info(
                        "Wait before target reconnect",
                        metadata: [
                            "phase": "target_reconnect", "attempt": .string(String(targetRetry.attempts)),
                            "delaySeconds": .string(String(delay)),
                        ])
                    timings.measure("target.reconnect_wait") {
                        activity.measure(.coordinator, "targetReconnectWait") {
                            SourceRetryState.wait(seconds: delay, cancellation: cancellation, drain: drain)
                        }
                    }
                    if cancellation.isCancelled || drain.isCancelled {
                        if archive != nil && !started {
                            try state.archiveValidationStopped()
                        } else {
                            try require(state.targetUUID != nil, "target unavailable before identity was established")
                            try state.stopped()
                        }
                        return stoppedResult()
                    }
                    pipeline = ApplyPipeline(
                        maximumItemBytes: configuration.source.transactionLimits.retainedBytes
                            + Int(configuration.source.transactionLimits.wireBytes) + 65536)
                }
            }
        } catch {
            let reason: String
            let code = (error as? ApplyError)?.code
            if let live = error as? LiveInspectionError {
                reason = live.reason
            } else {
                reason = String(describing: error)
            }
            sourceFailurePosition = (error as? ArchiveReadError)?.coordinate ?? (error as? TransactionError)?.coordinate
            if replayReadinessRejected && initialize && !started {
                // A new state has no work to reconcile. Reuse the same empty,
                // resumable state marker as cancellation before archive validation.
                try state.archiveValidationStopped()
                let result = summary("STOPPED")
                finalResult = result
                throw ApplyRunError(reason: reason, progress: result, code: code)
            }
            // A rejected resume/preflight must not rewrite the saved checkpoint.
            if !initialize && !started { throw ApplyRunError(reason: reason, progress: summary("STOPPED"), code: code) }
            if let sourceFailurePosition { try? state.recordSourceFailure(reason, at: sourceFailurePosition) }
            recoveryAdvice = try? state.recoveryAdvice(
                failure: targetFailure, sourceFailure: sourceFailurePosition != nil)
            ApplicationLog.logger.info(
                "Replication blocked; inspect the final diagnostic and saved state",
                metadata: [
                    "lifecycle": "BLOCKED", "reasonCode": .string(code?.rawValue ?? "apply_failed"),
                ])
            do { try state.block(reason) } catch {
                throw ApplyRunError(
                    reason: reason + "; additionally failed to persist BLOCKED diagnostic",
                    progress: summary("BLOCKED"), code: code)
            }
            throw ApplyRunError(reason: reason, progress: summary("BLOCKED"), code: code)
        }
    }
}
