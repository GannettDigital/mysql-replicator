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
        let state = try StateStore(configuration:configuration,initialize:initialize,timings:timings)
        func summary(_ lifecycle: String) -> ApplySummary {
            ApplySummary(lifecycle:lifecycle,transactionsApplied:state.transactions,rowsApplied:state.rows,ddlApplied:state.ddlApplied,
                appliedPosition:state.applied,appliedGTIDSet:state.gtids,pendingGTID:state.pendingGTID,stateDirectory:state.directory.path,stageTimings:lifecycle == "RUNNING" ? nil : timings.snapshot)
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
                        lock:target.lock,write:target.apply,completedGroup:target.completedDMLGroup)
                    try emitProgress(summary("RUNNING"))
                }
            }
            do {
                _ = try LiveInspection.run(configuration:capture,password:sourcePassword,includeRaw:true,cancellation:cancellation,
                    emitEvent: { record in
                        if !cancellation.isCancelled { try batch.flushIfExpired() }
                        try target.releaseExpiredLock()
                        try timings.measure("relay.append") { try state.append(record) }
                    },emitTransaction: { group in
                        if group.outcome == .statement {
                            try batch.flush()
                            try state.begin(group)
                            try target.unlock()
                            try require(group.events.count == 2, "invalid standalone DDL group")
                            guard case .query(let query)=group.events[1].control else {throw ApplyError("missing DDL query")}
                            if try filter.ignores(query) {
                                try state.complete(group,rowCount:0,filtered:true)
                                try emitProgress(summary("RUNNING")); return
                            }
                            let statement=try DDLStatement.from(group)
                            let plan=try target.prepareDDL(statement,query:query)
                            try state.ddlIntent(plan,event:group.events[1],coordinate:group.start)
                            try require(!cancellation.isCancelled,"apply cancelled")
                            try target.applyDDL(plan)
                            try state.complete(group,rowCount:0,ddl:plan)
                            try emitProgress(summary("RUNNING"))
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
                            try emitProgress(summary("RUNNING")); return
                        }
                        try batch.append(PreparedDMLGroup(group:group,mutations:mutations,relayEnd:state.relayLength))
                    },resolveSchema: { event, coordinate in
                        let table = try target.discover(event)
                        try state.schema(table,event:event,coordinate:coordinate)
                        return try (event.wireColumns ?? []).map { column in
                            guard let kind = column.interpretation else {throw ApplyError("missing wire interpretation")}
                            return kind
                        }
                    },timings:timings,onIdle:{
                        if !cancellation.isCancelled { try batch.flush() }
                        try target.unlock()
                    },allowDDL:true,ignoreTable: filter.patterns.isEmpty ? nil : { filter.ignores(database:$0,table:$1) })
                try batch.flush() // Includes stopAfterTransactions and clean source EOF.
            } catch {
                guard canStopCleanly(error, pendingGTID: state.pendingGTID) else { throw error }
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
