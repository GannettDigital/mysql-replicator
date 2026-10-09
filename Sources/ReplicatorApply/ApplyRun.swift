import Foundation
import ReplicatorCapture
import ReplicatorCodec

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
    // Crash recovery / uncertain target replay remains unsupported.
    public let automaticRecovery = false
}
public struct ApplyRunError: Error, CustomStringConvertible {
    public let reason: String
    public let progress: ApplySummary
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
    public static func run(configuration: ApplyConfiguration, sourcePassword: String, targetPassword: String,
                           initialize: Bool = false, cancellation: CaptureCancellation = .init(), drain: CaptureCancellation = .init(), archive: ArchiveReplay? = nil, control: RunControl? = nil, emitProgress: @escaping (ApplySummary) throws -> Void = { _ in }) throws -> ApplySummary {
        try configuration.validate(offline:archive != nil)
        if archive != nil { try require(configuration.source.mode == "gtid","offline replay requires GTID positioning") }
        let profile = configuration.replicationProfile
        let legacyMetadata = profile.sourceContract.requiresHistoricalSchema
        let filter = try TableFilter(configuration.replicateWildIgnoreTable ?? [])
        let timings = StageTimings()
        let producerTimings = StageTimings()
        let targetTimings = StageTimings()
        var pipeline = ApplyPipeline()
        var retry = SourceRetryState(policy:configuration.reconnectPolicy)
        var reconnectReason: String?
        var targetRetry = SourceRetryState(policy:configuration.targetReconnectPolicy)
        var targetReason: String?
        var targetFailure: TargetFailureDiagnostic?
        var consumerPending = false
        var limits=try StopConditions(transactions:configuration.source.stopAfterTransactions,gtids:configuration.source.stopAfterGTIDs)
        var stopReason: String?
        var finalResult: ApplySummary?
        var activeBatchTransactions=0
        let state = try StateStore(configuration:configuration,initialize:initialize,timings:timings)
        func finalTimings() -> [String:StageTimings.Sample] {
            let merged = StageTimings()
            merged.merge(timings.snapshot); merged.merge(producerTimings.snapshot); merged.merge(targetTimings.snapshot)
            return merged.snapshot
        }
        func summary(_ lifecycle: String) -> ApplySummary {
            ApplySummary(lifecycle:lifecycle,transactionsApplied:state.transactions,rowsApplied:state.rows,ddlApplied:state.ddlApplied,
                appliedPosition:state.applied,appliedGTIDSet:state.gtids,pendingGTID:state.pendingGTID,stateDirectory:state.directory.path,stageTimings:["RUNNING","DRAINING"].contains(lifecycle) ? nil : finalTimings(),
                pipeline:lifecycle == "RUNNING" ? nil : pipeline.queue.snapshot,
                sourceReconnectEnabled:archive == nil && configuration.reconnectPolicy.enabled,sourceReconnectAttempts:retry.attempts,sourceReconnectReason:reconnectReason,
                targetReconnectEnabled:configuration.targetReconnectPolicy.enabled,targetReconnectAttempts:targetRetry.attempts,
                targetReconnectReason:targetReason,targetFailure:targetFailure,drainRequested:drain.isCancelled,stopReason:stopReason,activeBatchTransactions:activeBatchTransactions)
        }
        func report(_ value: ApplySummary) throws {
            control?.publish(value);try emitProgress(value)
        }
        func stoppedResult() -> ApplySummary {
            if drain.isCancelled { stopReason="drainRequested" }
            let result=summary("STOPPED");finalResult=result;return result
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
        do {
          control?.publish(summary("STARTING"))
          try control?.start(directory:state.directory)
          if let archive { try archive.validate(baseline:state.gtids,stopAfterGTIDs:limits.stopAfterGTIDs) }
          while true {
           do {
            let target = try TargetSession(configuration:configuration,password:targetPassword,timings:targetTimings)
            defer { try? target.unlock() }
            try target.preflight()
            if !filter.patterns.isEmpty {
                try require(try target.query("SELECT @@lower_case_table_names AS n").0.first?.column("n")?.string == "0", "wildcard filtering requires lower_case_table_names=0")
            }
            try state.bindTargetIdentity(target.targetUUID!)
            for table in state.currentSchemas where !filter.ignores(database: table.database, table: table.table) {
                try require(try target.readSchema(database:table.database,name:table.table) == table,"target schema differs from saved checkpoint")
                // DDL barriers must see every validated saved table, including
                // tables with no row event since resume (e.g. DROP DATABASE).
                target.discovered[table.identity]=table
            }
            try state.running(); started = true
            targetReason=nil
            try progress()
            let executor = DMLExecutor()
            let executionStop = CaptureCancellation(parent:cancellation)
            func checkSourceFailure() throws {
                try pipeline.queue.checkFailure(allowSourceReconnect:configuration.reconnectPolicy.enabled,allowDrain:true)
            }
            var planningCache = try DMLPlanningCache(target.discovered,compatibility:configuration.compatibilityPolicy,legacyMetadata:legacyMetadata)
            func finishExecution() throws {
                guard executor.active else { return }
                let outcome = timings.measure("apply.execution_wait") { executor.join()! }
                if let diagnostic=outcome.diagnostic { targetFailure=diagnostic }
                try outcome.record(in:state)
                activeBatchTransactions=0
                try progress()
            }
            // Always join before target destruction, diagnostics or a journal
            // error path. Main-thread failures stop further target statements.
            defer { executionStop.cancel(); _ = executor.join() }
            let batch = DMLBatch(policy:configuration.batchPolicy,onFlush:{ reason in timings.measure("apply.batch.flush." + reason) {} }) { groups in
                try finishExecution()
                try checkSourceFailure()
                try target.lock(groups[0].mutations[0].table)
                try timings.measure("apply.batch.prepare") { try state.beginBatch(groups) }
                activeBatchTransactions=groups.count
                control?.publish(summary("RUNNING"))
                let byteLimit = target.insertByteLimit
                executor.start {
                    targetTimings.measure("apply.batch.execute") {
                        target.execute(groups,cancellation:executionStop,maximumInsertBytes:byteLimit,checkSourceFailure:checkSourceFailure)
                    }
                }
                if !configuration.batchPolicy.overlapPreparation { try finishExecution() }
            }
            func barrier(_ reason: String = "barrier") throws { try batch.flush(reason:reason); try finishExecution() }
            func maintainExecution() throws {
                if executor.ready { try finishExecution() }
                if !executor.active { try target.checkConnection(); try target.releaseExpiredLock() }
            }
            func event(_ record: LiveRecord) throws {
                if !cancellation.isCancelled { try batch.flushIfExpired() }
                try maintainExecution()
                try timings.measure("relay.append") { try state.append(record) }
                if let decoded = record.event {
                    if case .gtid = decoded.control { consumerPending = true }
                    if decoded.eventType == 19 && !decoded.replicationFiltered {
                        guard let database = decoded.database, let name = decoded.table else { throw ApplyError("missing table-map identity") }
                        let identity = database + "\0" + name
                        let table: ApplyTable
                        if planningCache.tables[identity] != nil {
                            table = try state.profile("target.discover") { try planningCache.validate(decoded) }
                        } else {
                            try barrier()
                            table = try target.discover(decoded)
                            try planningCache.insert(table)
                            _ = try planningCache.validate(decoded)
                        }
                        guard let offset = UInt64(decoded.offset) else { throw ApplyError("invalid table-map coordinate") }
                        try state.schema(table,event:decoded,coordinate:BinlogCoordinate(file:record.file,position:offset))
                    }
                }
            }
            func transaction(_ group: CompleteTransaction) throws {
                defer { consumerPending = false }
                if group.outcome == .statement {
                    try barrier()
                    target.statementTrace = .init()
                    try state.begin(group)
                    control?.publish(summary("RUNNING"))
                    do {
                    try target.unlock()
                    try require(group.events.count == 2, "invalid standalone DDL group")
                    guard case .query(let query)=group.events[1].control else {throw ApplyError("missing DDL query")}
                    if let skipped = try (configuration.ddlPolicy ?? DDLPolicy()).skippedQuery(query,profile:profile) {
                        try state.complete(group,rowCount:0,filtered:true,skippedDDL:skipped)
                        try progress(); return
                    }
                    if try filter.ignores(query) {
                        try state.complete(group,rowCount:0,filtered:true)
                        try progress(); return
                    }
                    let statement=try DDLStatement.from(group,profile:profile)
                    let plan=try target.prepareDDL(statement,query:query,timestamp:UInt64(group.events[1].timestamp))
                    try state.ddlIntent(plan,event:group.events[1],coordinate:group.start)
                    try require(!cancellation.isCancelled,"apply cancelled")
                    try checkSourceFailure()
                    try target.applyDDL(plan)
                    planningCache = try DMLPlanningCache(target.discovered,compatibility:configuration.compatibilityPolicy,legacyMetadata:legacyMetadata)
                    try state.complete(group,rowCount:0,ddl:plan)
                    try progress()
                    return
                    } catch {
                        let failedQuery=group.events.compactMap { event -> QueryControl? in
                            if case .query(let query)=event.control { return query }; return nil
                        }.first
                        let diagnostic=TargetFailureDiagnostic(reason:String(describing:error),statement:target.statementTrace,
                            rows:[],ddlGTID:state.pendingGTID,ddlSQL:failedQuery.map { String(decoding:$0.sql,as:UTF8.self) },
                            ddlContext:failedQuery.flatMap { DDLQueryContextDiagnostic(query:$0) })
                        targetFailure=diagnostic; try state.recordTargetFailure(diagnostic)
                        if error is TargetConnectionFailure && target.statementTrace.phase == .notIssued {
                            try state.discardUnwrittenPending()
                        }
                        throw error
                    }
                }
                let mutations: [Mutation]
                do { mutations = try state.profile("dml.plan") { try DMLPlan.make(group,tables:planningCache.tables,transactional:profile.transactional) } }
                catch {
                    try barrier()
                    try state.begin(group) // Keep rejected, unwritten groups explicitly skippable.
                    throw error
                }
                if mutations.isEmpty {
                    try barrier()
                    try target.unlock()
                    try state.begin(group)
                    try state.complete(group,rowCount:0,filtered:true)
                    try progress(); return
                }
                try batch.append(PreparedDMLGroup(group:group,mutations:mutations,relayEnd:state.relayLength))
            }
            while true {
              if drain.isCancelled { try report(summary("DRAINING")); try state.discardUnappliedCapture(); break }
              if let reason=limits.reason(transactions:state.transactions-initialTransactions,executed:try GTIDSet(state.gtids)) {
                  stopReason=reason == "gtidsSatisfied" && state.transactions == initialTransactions ? "alreadySatisfied" : reason
                  break
              }
              let remaining = limits.stopAfterTransactions.map { $0-(state.transactions-initialTransactions) }
              var capture = try state.captureConfiguration(configuration.source,remainingTransactions:remaining)
              capture.stopAfterTransactions=remaining;capture.stopAfterGTIDs=limits.stopAfterGTIDs
              do {
                try pipeline.run(cancellation:cancellation,producerTimings:producerTimings,produce:{ stop, send in
                    let resolver: ((DecodedEvent,BinlogCoordinate) throws -> [ColumnInterpretation])? = legacyMetadata ? { event,_ in
                        let request = ApplySchemaRequest(event)
                        try send(.schema(request))
                        return try request.wait(cancellation:stop)
                    } : nil
                    if let archive {
                        try archive.run(configuration:capture,cancellation:stop,
                            emitEvent:{ try send(.event($0)) },emitTransaction:{ try send(.transaction($0)) },
                            resolveSchema:resolver,timings:producerTimings,
                            ignoreTable:filter.patterns.isEmpty ? nil : { filter.ignores(database:$0,table:$1) })
                    } else {
                    _ = try LiveInspection.run(configuration:capture,password:sourcePassword,includeRaw:true,cancellation:stop,
                        emitEvent:{ try send(.event($0)) },emitTransaction:{ try send(.transaction($0)) },
                        resolveSchema:resolver,
                        timings:producerTimings,onIdle:{ try send(.idle) },allowDDL:true,
                        ignoreTable:filter.patterns.isEmpty ? nil : { filter.ignores(database:$0,table:$1) },sourceContract:profile.sourceContract)
                    }
                },consume:{ message in
                    if drain.isCancelled { throw ApplyDrainRequested() }
                    if control?.reloadRequested == true { throw ApplyReloadRequested() }
                    try timings.measure("apply.consume") {
                        switch message {
                        case .event(let record): try event(record)
                        case .transaction(let group): try transaction(group)
                        case .schema(let request):
                            do {
                                guard let db=request.event.database,let name=request.event.table else { throw ApplyError("missing schema identity") }
                                let identity = db + "\0" + name
                                if planningCache.tables[identity] == nil {
                                    try barrier("schema")
                                    let table = try target.discover(request.event)
                                    try planningCache.insert(table)
                                }
                                let table = try planningCache.validate(request.event)
                                request.complete(.success(table.columns.map(\.interpretation)))
                            } catch { request.complete(.failure(error)); throw error }
                        case .idle:
                            if !cancellation.isCancelled { try barrier("idle") }
                            else { try finishExecution() }
                            try target.unlock()
                        }
                    }
                },onWait:{
                    if drain.isCancelled { throw ApplyDrainRequested() }
                    if control?.reloadRequested == true { throw ApplyReloadRequested() }
                    if !cancellation.isCancelled { try batch.flushIfExpired() }
                    try maintainExecution()
                },timings:timings)
                if drain.isCancelled {
                    try report(summary("DRAINING"))
                    try finishExecution(); try state.discardUnappliedCapture(); batch.discard()
                } else { try barrier("end") } // Includes finite capture and clean EOF.
                stopReason=limits.reason(transactions:state.transactions-initialTransactions,executed:try GTIDSet(state.gtids)) ?? "endOfInput"
                break
              } catch {
                let sourceInterrupted = configuration.reconnectPolicy.enabled
                    && (error as? LiveInspectionError)?.isRetryableSourceFailure == true
                let draining = error is ApplyDrainRequested
                let reloading = error is ApplyReloadRequested
                if !sourceInterrupted && !draining && !reloading { executionStop.cancel() }
                if draining { try report(summary("DRAINING")) }
                // Preserve acknowledged work even if preparation/decoding failed.
                // Unwritten collected work is discarded; uncertain SQL is never retried.
                do { try finishExecution() }
                catch let executionError {
                    if sourceInterrupted || draining || reloading { throw executionError }
                    throw ApplyError("\(error); target completion: \(executionError)")
                }
                if draining {
                    try state.discardUnappliedCapture()
                    batch.discard(); consumerPending=false
                    break
                }
                if reloading,let control {
                    try state.discardUnappliedCapture();batch.discard();consumerPending=false
                    try target.unlock()
                    do {
                        let candidate=try control.candidate()
                        try require(candidate.reason(transactions:state.transactions-initialTransactions,executed:try GTIDSet(state.gtids)) == nil,
                            "new stop condition is already satisfied after issued work; it cannot rewind the target")
                        if let archive { try archive.validate(baseline:state.gtids,stopAfterGTIDs:candidate.stopAfterGTIDs) }
                        limits=candidate
                        control.publish(summary("RUNNING"));control.acknowledge(.success(candidate))
                    } catch { control.publish(summary("RUNNING"));control.acknowledge(.failure(error)) }
                    pipeline=ApplyPipeline()
                    continue
                }
                if sourceInterrupted {
                    // The pipeline and receiver have joined. Only acknowledged,
                    // journaled target work may advance the restart boundary.
                    try state.discardUnappliedCapture()
                    batch.discard(); consumerPending=false
                    try target.unlock()
                    if cancellation.isCancelled || drain.isCancelled { break }
                    if let reason=limits.reason(transactions:state.transactions-initialTransactions,executed:try GTIDSet(state.gtids)) { stopReason=reason;break }
                    reconnectReason=String(describing:error)
                    let delay: Int
                    do { delay = try retry.nextDelay(appliedTransactions:state.transactions) }
                    catch { throw ApplyError("\(error); last source failure: \(reconnectReason!)") }
                    try report(summary("RECONNECTING"))
                    timings.measure("source.reconnect_wait") { SourceRetryState.wait(seconds:delay,cancellation:cancellation,drain:drain) }
                    if cancellation.isCancelled || drain.isCancelled { break }
                    pipeline=ApplyPipeline()
                    reconnectReason=nil
                    continue
                }
                guard !consumerPending && canStopCleanly(error, pendingGTID: state.pendingGTID) else { throw error }
                break
              }
            }
            try target.unlock()
            try state.stopped()
            return stoppedResult()
           } catch {
            guard error is TargetConnectionFailure, configuration.targetReconnectPolicy.enabled,
                  state.pendingGTID == nil else { throw error }
            // The old target session and its executor have been destroyed before
            // reconnect. Only fully acknowledged groups can advance this boundary.
            try state.discardUnappliedCapture()
            consumerPending=false
            targetReason=String(describing:error)
            if cancellation.isCancelled || drain.isCancelled {
                try require(state.targetUUID != nil,"target unavailable before identity was established")
                try state.stopped(); return stoppedResult()
            }
            let delay: Int
            do { delay = try targetRetry.nextDelay(appliedTransactions:state.transactions) }
            catch { throw ApplyError("target reconnect attempts exhausted; last failure: \(targetReason!)") }
            try report(summary("TARGET_RECONNECTING"))
            timings.measure("target.reconnect_wait") { SourceRetryState.wait(seconds:delay,cancellation:cancellation,drain:drain) }
            if cancellation.isCancelled || drain.isCancelled {
                try require(state.targetUUID != nil,"target unavailable before identity was established")
                try state.stopped(); return stoppedResult()
            }
            pipeline=ApplyPipeline()
           }
          }
        } catch {
            let reason: String
            if let live = error as? LiveInspectionError { reason = live.reason }
            else { reason = String(describing:error) }
            // A rejected resume/preflight must not rewrite the saved checkpoint.
            if !initialize && !started { throw ApplyRunError(reason:reason,progress:summary("STOPPED")) }
            do { try state.block(reason) }
            catch { throw ApplyRunError(reason:reason + "; additionally failed to persist BLOCKED diagnostic",progress:summary("BLOCKED")) }
            throw ApplyRunError(reason:reason,progress:summary("BLOCKED"))
        }
    }
}
