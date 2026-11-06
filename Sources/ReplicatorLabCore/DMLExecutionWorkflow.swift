import Foundation

/// Opt-in histories retain intermediate matrix results until one final read.
/// Client requests keep their original SQL and declared source transaction counts.
struct DMLExecutionWorkflow {
    enum Order: String {
        case id = "id"
        case idOrdinal = "id+0"
    }
    struct History {
        let table: String
        let throughPhase: Int
    }
    struct Batch {
        let id: String
        let writes: [LabSQLPhase.Write]
        let transactions: [Int]
        var jsonDiffChecks: [LabJSONDiff.Check] = []

        var transactionCount: Int { transactions.reduce(0, +) }

        func validate(_ results: [LabSQLPhase.Result]) throws -> [Int] {
            try require(
                results.count == writes.count && transactions.count == writes.count,
                "DML batch request count differs: " + id)
            for check in jsonDiffChecks { _ = try check.window(results) }
            return try zip(zip(writes, transactions), results).map { pair, result in
                let (write, expected) = pair
                try require(
                    result.write.id == write.id && LabSQLName.equal(result.write.sql, write.sql),
                    "DML batch request differs: " + id)
                let actual = try DMLCompatibilityCases.transactionCount(result.gtids)
                try require(actual == expected, "DML source transaction count differs: " + write.id)
                return actual
            }
        }
    }
    struct Plan {
        let prepare: Batch
        let body: Batch
        let cleanup: Batch
        let final: DDLFinalObservations
        let expectedDDL: Int
        let expectedRows: Int

        func validateProgress(before: [String: Any], after: [String: Any], end: Boundary, cleaned: Bool) throws {
            let transactions =
                prepare.transactionCount + body.transactionCount + (cleaned ? cleanup.transactionCount : 0)
            for (key, expected) in [
                ("transactionsApplied", transactions), ("ddlApplied", expectedDDL + (cleaned ? 1 : 0)),
                ("rowsApplied", expectedRows),
            ] {
                guard let old = before[key] as? Int, let new = after[key] as? Int else {
                    throw LabError("missing DML counter: " + key)
                }
                try require(new - old == expected, "DML workflow counter differs: " + key)
            }
            guard let position = after["appliedPosition"] as? [String: Any], let offset = position["position"] else {
                throw LabError("missing DML workflow applied position")
            }
            try require(
                after["appliedGTIDSet"] as? String == end.gtids && position["file"] as? String == end.file
                    && String(describing: offset) == String(end.position), "DML workflow checkpoint differs")
        }
    }

    let title: String
    let histories: [History]
    let phaseTransactions: [Int]
    let predicateIDs: [String]
    let additionalChecks: [DDLFinalObservations.Observation]
    let expectedDDL: Int
    let expectedRows: Int
    // Fixed final queries declare this ordering; it is not arbitrary SQL.
    var order: Order = .id
    // A flagged phase needs an explicit bounded source-event check.
    var jsonDiffPhases: [LabJSONDiff.Phase] = []

    func plan(_ test: DMLCompatibilityCases.Case) throws -> Plan {
        func validName(_ value: String) -> Bool {
            !value.isEmpty
                && value.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
                }
        }
        try require(validName(test.id) && !title.isEmpty, "invalid DML workflow identity")
        try require(
            test.setup.isEmpty && test.orderBy == order.rawValue && test.replicatedReplacement == nil,
            "DML workflow needs an explicit plan for setup, ordering or replacement")
        try require(
            !test.phases.isEmpty && phaseTransactions.count == test.phases.count
                && phaseTransactions.allSatisfy { $0 > 0 }, "DML workflow phase transaction counts differ")
        let flagged = test.phases.enumerated().filter { $0.element.expectsJSONDiff }.map { $0.offset + 1 }
        try require(
            jsonDiffPhases.map(\.phase) == flagged
                && jsonDiffPhases.allSatisfy { phaseTransactions[$0.phase - 1] == 1 },
            "DML workflow needs an exact single-transaction plan for every JSON diff phase")
        try require(
            predicateIDs.count == test.phases.count && !predicateIDs.contains(where: \.isEmpty),
            "DML workflow predicate names differ")
        try require(expectedDDL > 0 && expectedRows >= 0, "invalid DML workflow counters")
        let original = "matrix_" + test.id
        try require(histories.allSatisfy { validName($0.table) && $0.table != original }, "invalid retained DML table")
        try require(
            Set(histories.map(\.table)).count == histories.count
                && Set(histories.map(\.throughPhase)) == Set(1..<test.phases.count)
                && histories.count == test.phases.count - 1, "DML workflow must retain every earlier phase exactly once"
        )
        let table = "poc." + original
        func create(_ name: String) -> String {
            "CREATE TABLE poc." + name + "(" + test.definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
        }
        let prepare = Batch(
            id: "prepare",
            writes: [LabSQLPhase.Write(id: "create-original", sql: create(original))]
                + histories.map { .init(id: "create-" + $0.table, sql: create($0.table)) },
            transactions: Array(repeating: 1, count: histories.count + 1))
        var writes = test.phases.enumerated().map { index, phase in
            LabSQLPhase.Write(id: "original-phase-\(index + 1)", sql: "USE poc; " + phase.sql)
        }
        var counts = phaseTransactions
        var diffChecks = jsonDiffPhases.map {
            LabJSONDiff.Check(writeID: "original-phase-\($0.phase)", table: table, operation: $0.operation)
        }
        for history in histories {
            for (index, phase) in test.phases.prefix(history.throughPhase).enumerated() {
                writes.append(
                    .init(
                        id: history.table + "-phase-\(index + 1)",
                        sql: "USE poc; " + phase.sql.replacingOccurrences(of: table, with: "poc." + history.table)))
                counts.append(phaseTransactions[index])
                if let diff = jsonDiffPhases.first(where: { $0.phase == index + 1 }) {
                    diffChecks.append(
                        .init(
                            writeID: history.table + "-phase-\(index + 1)", table: "poc." + history.table,
                            operation: diff.operation))
                }
            }
        }
        let cleanupSQL = "DROP TABLE " + histories.map { "poc." + $0.table }.joined(separator: ",")
        let checks = try test.phases.enumerated().map { index, phase -> DDLFinalObservations.Observation in
            let name: String
            if index == test.phases.count - 1 {
                name = table
            } else {
                guard let retained = histories.first(where: { $0.throughPhase == index + 1 }) else {
                    throw LabError("missing DML phase history")
                }
                name = "poc." + retained.table
            }
            return .init(
                id: predicateIDs[index], check: .init(phase.check.replacingOccurrences(of: table, with: name), "1"))
        }
        let final = DDLFinalObservations(checks: checks + additionalChecks, databases: ["poc"], cleanup: [cleanupSQL])
        try final.validateQueries()
        return Plan(
            prepare: prepare, body: .init(id: "body", writes: writes, transactions: counts, jsonDiffChecks: diffChecks),
            cleanup: .init(
                id: "cleanup", writes: [.init(id: "drop-retained-tables", sql: cleanupSQL)], transactions: [1]),
            final: final, expectedDDL: expectedDDL, expectedRows: expectedRows)
    }
}

extension SharedCorrectness.Run {
    func dmlWorkflow(_ workflow: DMLExecutionWorkflow, test: DMLCompatibilityCases.Case) throws {
        let plan = try workflow.plan(test)
        let caseID = "matrix-" + test.id
        guard let before = try applier.latestProgress() else { throw LabError("missing DML workflow initial progress") }
        func submit(_ batch: DMLExecutionWorkflow.Batch) throws -> [LabSQLPhase.Result] {
            var captured: [LabSQLPhase.Result] = []
            try assertion(batch.id, caseID: caseID) {
                captured = try sourcePhase(caseID + "-" + batch.id, writes: batch.writes, database: "poc")
                return ["writes": captured.map(\.json), "transactionCounts": try batch.validate(captured)]
                    as [String: Any]
            }
            return captured
        }
        _ = try submit(plan.prepare)
        let body = try submit(plan.body)
        func checkpoint(_ id: String, end: Boundary, cleaned: Bool) throws {
            try assertion(id, caseID: caseID) {
                guard let progress = try applier.latestProgress() else {
                    throw LabError("missing DML workflow progress")
                }
                try plan.validateProgress(before: before, after: progress, end: end, cleaned: cleaned)
                return ["before": before, "after": progress, "source": end.json]
            }
        }
        try checkpoint("body-checkpoint", end: body.last!.end, cleaned: false)
        try verifyJSONDiffs(plan.body.jsonDiffChecks, results: body, caseID: caseID)
        try ddlFinalObservations(plan.final, caseID: caseID)
        let cleanup = try submit(plan.cleanup)
        try checkpoint("cleanup-checkpoint", end: cleanup.last!.end, cleaned: true)
    }
}
