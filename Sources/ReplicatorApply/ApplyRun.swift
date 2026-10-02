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

    /// One connection attempt, either new state or an explicitly resumed clean stop.
    /// Interrupted runs and uncertain target outcomes are never retried.
    public static func run(configuration: ApplyConfiguration, sourcePassword: String, targetPassword: String,
                           initialize: Bool = false, cancellation: CaptureCancellation = .init(), emitProgress: @escaping (ApplySummary) throws -> Void = { _ in }) throws -> ApplySummary {
        try configuration.validate()
        let filter = try TableFilter(configuration.replicateWildIgnoreTable ?? [])
        let timings = StageTimings()
        let producerTimings = StageTimings()
        let pipeline = ApplyPipeline()
        var consumerPending = false
        let state = try StateStore(configuration:configuration,initialize:initialize,timings:timings)
        func summary(_ lifecycle: String) -> ApplySummary {
            ApplySummary(lifecycle:lifecycle,transactionsApplied:state.transactions,rowsApplied:state.rows,ddlApplied:state.ddlApplied,
                appliedPosition:state.applied,appliedGTIDSet:state.gtids,pendingGTID:state.pendingGTID,stateDirectory:state.directory.path,stageTimings:lifecycle == "RUNNING" ? nil : timings.snapshot.merging(producerTimings.snapshot) { current, _ in current },
                pipeline:lifecycle == "RUNNING" ? nil : pipeline.queue.snapshot)
        }
        func progress() throws {
            // Include snapshot construction, JSON encoding and the synchronous
            // output callback so stdout backpressure is visible in final timings.
            try timings.measure("progress.emit") { try emitProgress(summary("RUNNING")) }
        }
        let capture = try state.captureConfiguration(configuration.source)
        var started = false
        do {
            let target = try TargetSession(configuration:configuration,password:targetPassword,timings:timings)
            defer { try? target.unlock() }
            try target.preflight()
            if !filter.patterns.isEmpty {
                try require(try target.query("SELECT @@lower_case_table_names AS n").0.first?.column("n")?.string == "0", "wildcard filtering requires lower_case_table_names=0")
            }
            try state.bindTargetIdentity(target.targetUUID!)
            for table in state.currentSchemas where !filter.ignores(database: table.database, table: table.table) {
                try require(try target.readSchema(database:table.database,name:table.table) == table,"target schema differs from saved checkpoint")
            }
            try state.running(); started = true
            let batch = DMLBatch(policy:configuration.batchPolicy) { groups in
                try timings.measure("apply.batch") {
                    try DMLBatch.execute(groups,state:state,cancellation:cancellation,
                        lock:{ try pipeline.queue.checkFailure(); try target.lock($0) },
                        write:{ try pipeline.queue.checkFailure(); try target.apply($0) },completedGroup:target.completedDMLGroup)
                    try progress()
                }
            }
            func event(_ record: LiveRecord) throws {
                if !cancellation.isCancelled { try batch.flushIfExpired() }
                try target.releaseExpiredLock()
                try timings.measure("relay.append") { try state.append(record) }
                if let decoded = record.event {
                    if case .gtid = decoded.control { consumerPending = true }
                    if decoded.eventType == 19 && !decoded.replicationFiltered {
                        let table = try target.discover(decoded)
                        guard let offset = UInt64(decoded.offset) else { throw ApplyError("invalid table-map coordinate") }
                        try state.schema(table,event:decoded,coordinate:BinlogCoordinate(file:record.file,position:offset))
                    }
                }
            }
            func transaction(_ group: CompleteTransaction) throws {
                defer { consumerPending = false }
                if group.outcome == .statement {
                    try batch.flush()
                    try state.begin(group)
                    try target.unlock()
                    try require(group.events.count == 2, "invalid standalone DDL group")
                    guard case .query(let query)=group.events[1].control else {throw ApplyError("missing DDL query")}
                    if try filter.ignores(query) {
                        try state.complete(group,rowCount:0,filtered:true)
                        try progress(); return
                    }
                    let statement=try DDLStatement.from(group)
                    let plan=try target.prepareDDL(statement,query:query)
                    try state.ddlIntent(plan,event:group.events[1],coordinate:group.start)
                    try require(!cancellation.isCancelled,"apply cancelled")
                    try pipeline.queue.checkFailure()
                    try target.applyDDL(plan)
                    try state.complete(group,rowCount:0,ddl:plan)
                    try progress()
                    return
                }
                let mutations: [Mutation]
                do { mutations = try DMLPlan.make(group,tables:Array(target.discovered.values)) }
                catch {
                    try batch.flush()
                    try state.begin(group) // Keep rejected, unwritten groups explicitly skippable.
                    throw error
                }
                if mutations.isEmpty {
                    try batch.flush()
                    try state.begin(group)
                    try target.unlock()
                    try state.complete(group,rowCount:0,filtered:true)
                    try progress(); return
                }
                try batch.append(PreparedDMLGroup(group:group,mutations:mutations,relayEnd:state.relayLength))
            }
            do {
                try pipeline.run(cancellation:cancellation,producerTimings:producerTimings,produce:{ stop, send in
                    _ = try LiveInspection.run(configuration:capture,password:sourcePassword,includeRaw:true,cancellation:stop,
                        emitEvent:{ try send(.event($0)) },emitTransaction:{ try send(.transaction($0)) },
                        timings:producerTimings,onIdle:{ try send(.idle) },allowDDL:true,
                        ignoreTable:filter.patterns.isEmpty ? nil : { filter.ignores(database:$0,table:$1) })
                },consume:{ message in
                    try timings.measure("apply.consume") {
                        switch message {
                        case .event(let record): try event(record)
                        case .transaction(let group): try transaction(group)
                        case .idle:
                            if !cancellation.isCancelled { try batch.flush() }
                            try target.unlock()
                        }
                    }
                },onWait:{
                    if !cancellation.isCancelled { try batch.flushIfExpired() }
                    try target.releaseExpiredLock()
                },timings:timings)
                try batch.flush() // Includes stopAfterTransactions and clean source EOF.
            } catch {
                guard !consumerPending && canStopCleanly(error, pendingGTID: state.pendingGTID) else { throw error }
            }
            try target.unlock()
            try state.stopped()
            return summary("STOPPED")
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
