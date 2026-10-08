import Foundation

/// Ordered engine-specific workflows; child cases are visible before execution.
enum SharedWorkflowCases {
    static let recovery: [QualificationCase] = [
        .init("multirow","Replicate multirow INSERT and DELETE with a primary-key update"),
        .init("exact-values","Preserve integer extremes, UTF-8 and binary bytes, NULL and empty values"),
        .init("discovery","Discover multiple tables with non-leading primary keys and persist their schemas"),
        .init("table-capacity","Discover and apply 160 tables in one session"),
        .init("composite-resume-initial","Create and persist a composite primary key at a clean stop"),
        .init("composite-resume","Resume a composite key through ADD, RENAME and key-changing DML"),
        .init("composite-collision","Reject a changed composite key occupied by another target row"),
        .init("schema-cache","Release idle table locks and reuse validated schema for following writes"),
        .init("absent-schema","Reject a missing target table without advancing the checkpoint"),
        .init("incompatible-schema","Reject target primary-key signedness incompatible with source metadata"),
        .init("existing","Reject initialization over an existing replication state directory"),
        .init("mismatch","Reject a before-image mismatch without changing rows or advancing progress"),
        .init("multistatement","Reject a multi-statement transaction; confirm native MyISAM error 1837"),
        .init("native-channel","Refuse to start while a native replication channel is running"),
        .init("trigger","Reject a target table with a trigger before applying rows"),
        .init("partial","Record partial MyISAM writes and pending intent after a duplicate-key failure"),
        .init("batch-crash","Kill a writer mid-group and retain all prepared intents without advancing progress"),
        .init("batch-crash-resume","Refuse automatic replay of a crashed prepared group"),
        .init("missing","Stop on a missing DELETE row without advancing the checkpoint")
    ]
    static let bootstrapTriggerSkip=QualificationCase("bootstrap-trigger-skip","Skip logged trigger definitions and preserve all effects and audit on a bootstrapped table")
    static var failures: [QualificationCase] {
        [DDLCompatibilityCases.trigger, DDLCompatibilityCases.event, bootstrapTriggerSkip,
         DDLCompatibilityCases.sourceTrigger, DDLCompatibilityCases.generatedMismatch, DDLCompatibilityCases.targetTrigger]
        + ModifyIndexCases.failures.map(\.test) + [ModifyIndexCases.timeout,
         DatabaseCreationCases.unsupported, DatabaseCreationCases.unsupportedDefault, DatabaseCreationCases.denied,
         DDLCoverageCases.missingTemplate] + DDLCoverageCases.rejections.map { $0.0 }
        + [DDLCoverageCases.unsupported, DDLCoverageCases.denied]
    }
    static func recovery(_ id: String) -> QualificationCase { recovery.first { $0.id == id }! }
    static func requirePassed(_ cases: [QualificationCase], in results: [[String:Any]]) throws {
        let passed=Set(results.filter { $0["status"] as? String == "passed" }.compactMap { $0["id"] as? String })
        let missing=Set(cases.map(\.id)).subtracting(passed)
        try require(missing.isEmpty,"workflow omitted required cases: "+missing.sorted().joined(separator:", "))
    }
}
