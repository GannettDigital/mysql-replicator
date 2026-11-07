import Foundation

/// Only cases with explicit phase ends use batched execution. Checks must be
/// observed before the next write, and deliberate restarts must start a phase.
struct DDLExecutionPhase {
    let id: String
    let steps: [DDLCompatibilityCases.Step]

    static func plan(_ steps: [DDLCompatibilityCases.Step]) throws -> [Self]? {
        guard steps.contains(where: { $0.phaseEnd != nil }) else { return nil }
        var phases: [Self] = []
        var pending: [DDLCompatibilityCases.Step] = []
        for step in steps {
            try require(!step.restartBefore || pending.isEmpty, "DDL restart must begin a phase")
            try require(step.assertionID == nil, "DDL phase cannot hide a per-statement assertion")
            try require(step.checks.isEmpty || step.phaseEnd != nil, "DDL checks require a phase boundary")
            pending.append(step)
            if let id = step.phaseEnd {
                try require(
                    !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                    "invalid DDL phase name: " + id)
                try require(!phases.contains { $0.id == id }, "duplicate DDL phase: " + id)
                phases.append(Self(id: id, steps: pending))
                pending = []
            }
        }
        try require(pending.isEmpty, "DDL sequence has no final observation boundary")
        return phases
    }

    func writes(transactional: Bool) -> [LabSQLPhase.Write] {
        steps.enumerated().map { index, step in
            // The old runner used a new client for each step. Reset session
            // overrides before the operation, so its SHOW WARNINGS stays intact.
            .init(
                id: id + "-statement-\(index + 1)",
                sql:
                    "SET SESSION auto_increment_increment=@@GLOBAL.auto_increment_increment,auto_increment_offset=@@GLOBAL.auto_increment_offset; "
                    + "SET SESSION timestamp=DEFAULT; "
                    + (transactional ? step.sqlTransactional : step.sql))
        }
    }

    /// CHECK and LOCAL statements must leave both GTIDs and file offsets unchanged.
    func validateUnlogged(_ results: [LabSQLPhase.Result]) throws -> Int {
        try require(results.count == steps.count, "DDL phase result count differs: " + id)
        var checked = 0
        for (step, result) in zip(steps, results) where step.transactions == 0 {
            try require(
                result.gtids.isEmpty && result.start.gtids == result.end.gtids
                    && result.start.file == result.end.file && result.start.position == result.end.position,
                "unlogged source operation changed the binlog: " + result.write.id)
            checked += 1
        }
        return checked
    }

    var checks: [DDLCompatibilityCases.Check] { steps.last!.checks }
    var queries: [LabSQLBatch.Query] {
        checks.enumerated().map { index, check in
            .init(
                name: "check-\(index + 1)", sql: "SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; " + check.sql,
                preserveWhitespace: true)
        }
    }

    func observations(_ values: [String: String], engine: String, role: String) throws -> [[String: Any]] {
        try checks.enumerated().map { index, check in
            let name = "check-\(index + 1)"
            guard let value = values[name] else { throw LabError("\(id)/\(role): missing " + name) }
            let expected = check.expected(engine: engine)
            try require(
                LabSQLName.equal(check.observation(value), expected),
                "\(id)/\(role): \(check.sql) got \(value), expected \(expected)")
            return ["query": check.sql, "expected": expected, "fields": check.fields ?? [], "value": value]
        }
    }
}

extension SharedCorrectness.Run {
    func ddlPhases(
        _ phases: [DDLExecutionPhase], test: DDLCompatibilityCases.Case,
        rowKeyObservations: [String: KeyRowLifecycleWorkflows.Observation] = [:]
    ) throws -> [LabSQLPhase.Result] {
        var captured: [LabSQLPhase.Result] = []
        try require(Set(rowKeyObservations.keys).isSubset(of: Set(phases.map(\.id))), "missing row/key observation phase")
        try test.finalObservations?.validate(phases)
        for phase in phases {
            if phase.steps[0].restartBefore {
                try assertion("resume-before-" + phase.id, caseID: test.test.id) {
                    try applier.drain()
                    try applier.start(initialize: false)
                    try wait()
                    return ["following_phase": phase.id, "progress": try applier.latestProgress() ?? [:]]
                }
            }
            try assertion(phase.id, caseID: test.test.id) {
                let writes = try sourcePhase(
                    test.test.id + "-" + phase.id,
                    writes: phase.writes(transactional: f.profile.transactionalTarget), database: "ddlcompat")
                captured += writes
                let unlogged = try phase.validateUnlogged(writes)
                if test.finalObservations != nil {
                    return ["writes": writes.map(\.json), "unloggedOperations": unlogged]
                }
                var observations: [String: Any] = [:]
                for role in LabProfile.Role.allCases {
                    let values = try f.h.sqlBatch(f.profile.service(role), phase.queries)
                    observations[role.rawValue] = try phase.observations(
                        values, engine: f.profile.engine(role), role: role.rawValue)
                }
                return [
                    "writes": writes.map(\.json), "checks": observations,
                    "snapshots": try compare("ddlcompat"),
                ]
            }
            if let observation = rowKeyObservations[phase.id] {
                try rowKeyObservation(observation, caseID: test.test.id)
            }
        }
        if let final = test.finalObservations {
            try ddlFinalObservations(final, caseID: test.test.id)
        }
        return captured
    }
}
