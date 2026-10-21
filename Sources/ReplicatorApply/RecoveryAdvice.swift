import Foundation
import ReplicatorCodec

/// These groups are durable but unresolved. A pending group is not proof that
/// its target write ran, failed, or committed.
public struct PendingTransactionPosition: Encodable {
    public let gtid: String
    public let start: BinlogCoordinate
    public let end: BinlogCoordinate
    init(_ group: CompleteTransaction) {
        gtid = group.gtid!.canonical
        start = group.start
        end = group.end
    }
}

/// Guidance does not authorize a retry. The offline recovery command validates
/// the journal again and requires an explicit operator decision and reason.
public struct RecoveryAdvice: Encodable {
    public let category: String
    public let reason: String
    public let requiresTargetReconciliation: Bool
    public let nextSteps: [String]

    static func make(
        transactional: Bool, pending: Int, rejectedDDL: Bool, hasDDLIntents: Bool,
        sourceFailure: Bool, targetUnbound: Bool
    ) -> Self {
        let inspect = "Stop the process and run recovery inspect --config <config>. Keep a support bundle."
        if rejectedDDL && !hasDDLIntents && pending == 1 {
            return .init(
                category: "rejectedDDL", reason: "The DDL was rejected before a target write intent was saved.",
                requiresTargetReconciliation: false,
                nextSteps: [
                    inspect,
                    "Correct the reported cause. Use recovery resolve retry with the pending GTID and a reason. Then resume without --initialize.",
                ])
        }
        if hasDDLIntents {
            return .init(
                category: "ddlReconciliationRequired",
                reason: "A saved DDL intent can represent a target schema change.",
                requiresTargetReconciliation: true,
                nextSteps: [
                    "Stop the process and collect a support bundle. Compare the source DDL, saved intent, and target schema.",
                    "Do not retry automatically. This recovery command does not resolve saved DDL intents.",
                ])
        }
        if pending > 0 {
            return .init(
                category: "targetReconciliationRequired",
                reason: "Pending transactions do not prove the target commit outcome.",
                requiresTargetReconciliation: true,
                nextSteps: transactional
                    ? [
                        inspect,
                        "Reconcile every pending transaction on the target. Then select retry, mark-applied, or skip with explicit GTIDs and a reason. Resume only after all pending transactions are resolved.",
                    ]
                    : [
                        "Stop the process and collect a support bundle. Reconcile all affected MyISAM tables.",
                        "Automatic retry and row recovery resolve are not supported for this target profile.",
                    ])
        }
        if (transactional && !targetUnbound) || (targetUnbound && sourceFailure) {
            return .init(
                category: "noPendingTransactions", reason: "No unresolved transaction is saved in the journal.",
                requiresTargetReconciliation: false,
                nextSteps: [
                    inspect,
                    "Correct the reported cause. Use recovery resolve retry --gtids none with a reason. Then resume without --initialize.",
                ])
        }
        return .init(
            category: "manualInspectionRequired", reason: "The saved state needs operator inspection before restart.",
            requiresTargetReconciliation: true,
            nextSteps: [inspect, "Do not retry automatically. Use the documented recovery limits for this profile."])
    }
}
