import Foundation
import ReplicatorCapture
import ReplicatorCodec

public struct ApplySummary: Encodable {
    public let kind = "apply_summary"
    public let lifecycle: String
    public let transactionsApplied: Int
    public let rowsApplied: Int
    public let appliedPosition: BinlogCoordinate?
    public let appliedGTIDSet: String
    public let pendingGTID: String?
    public let stateDirectory: String
    public let automaticRecovery = false
}
public struct ApplyRunError: Error, CustomStringConvertible {
    public let reason: String
    public let progress: ApplySummary
    public var description: String { reason }
}
public enum ApplyRun {
    /// Initial DML milestone: exactly one attempt and a new state directory.
    /// Existing state, interrupted runs and uncertain outcomes are never retried.
    public static func run(configuration: ApplyConfiguration, sourcePassword: String, targetPassword: String,
                           cancellation: CaptureCancellation = .init(), emitProgress: @escaping (ApplySummary) throws -> Void = { _ in }) throws -> ApplySummary {
        try configuration.validate()
        let state = try StateStore(configuration:configuration)
        func summary(_ lifecycle: String) -> ApplySummary {
            ApplySummary(lifecycle:lifecycle,transactionsApplied:state.transactions,rowsApplied:state.rows,
                appliedPosition:state.applied,appliedGTIDSet:state.gtids,pendingGTID:state.pendingGTID,stateDirectory:state.directory.path)
        }
        do {
            let target = try TargetSession(configuration:configuration,password:targetPassword)
            try target.preflight()
            try state.running()
            _ = try LiveInspection.run(configuration:configuration.source,password:sourcePassword,includeRaw:true,cancellation:cancellation,
                emitEvent:state.append,emitTransaction: { group in
                    try state.begin(group)
                    let mutations = try DMLPlan.make(group,tables:configuration.tables)
                    try target.lock(mutations[0].table)
                    var locked = true
                    defer { if locked { try? target.unlock() } }
                    for (index,mutation) in mutations.enumerated() {
                        try require(!cancellation.isCancelled,"apply cancelled")
                        try state.intent(index,mutation)
                        try target.apply(mutation)
                        try state.rowDone(index)
                    }
                    try state.complete(group,rowCount:mutations.count)
                    try target.unlock(); locked = false
                    try emitProgress(summary("RUNNING"))
                })
            try state.stopped()
            return summary("STOPPED")
        } catch {
            let reason: String
            if let live = error as? LiveInspectionError { reason = live.reason }
            else { reason = String(describing:error) }
            do { try state.block(reason) }
            catch { throw ApplyRunError(reason:reason + "; additionally failed to persist BLOCKED diagnostic",progress:summary("BLOCKED")) }
            throw ApplyRunError(reason:reason,progress:summary("BLOCKED"))
        }
    }
}
