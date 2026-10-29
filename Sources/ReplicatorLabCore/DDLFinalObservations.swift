import Foundation

/// Independent table sets retain ordinary results until one final query batch.
/// Cleanup follows the case's saved-state assertions, before the next case.
struct DDLFinalObservations {
    struct Observation {
        let id: String
        let check: DDLCompatibilityCases.Check
        var transactionalCheck: DDLCompatibilityCases.Check? = nil
        var fulltextParserIndex: String? = nil

        func selectedCheck(transactional: Bool) -> DDLCompatibilityCases.Check {
            transactional ? (transactionalCheck ?? check) : check
        }

        func result(_ values: [String: String], engine: String, role: String, transactional: Bool = false) throws
            -> [String: Any]
        {
            let check = selectedCheck(transactional: transactional)
            guard let value = values[id] else { throw LabError("\(id)/\(role): missing final observation") }
            let expected = check.expected(engine: engine)
            let observed =
                try fulltextParserIndex.map { try NativeFulltextParser.read(value, index: $0) }
                ?? check.observation(value)
            try require(
                LabSQLName.equal(observed, expected),
                "\(id)/\(role): \(check.sql) got \(value), expected \(expected)")
            var result: [String: Any] = [
                "query": check.sql, "value": value, "expected": expected, "fields": check.fields ?? [],
            ]
            if let index = fulltextParserIndex {
                result["fulltextIndex"] = index
                result["parser"] = observed
            }
            return result
        }
    }
    let checks: [Observation]
    let databases: [String]
    let cleanup: [String]

    var replayResetSQL: String {
        // This runs in one target-only session while the live writer is stopped.
        // Disabling FK checks permits removal of owned cross-database pairs.
        (["SET sql_log_bin=0", "SET FOREIGN_KEY_CHECKS=0"] + cleanup + [
            "DROP DATABASE ddlcompat",
            "CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            "SET FOREIGN_KEY_CHECKS=1",
        ]).joined(separator: "; ")
    }

    func validate(_ phases: [DDLExecutionPhase]) throws {
        try require(!phases.isEmpty, "final DDL observations require source phases")
        try require(
            phases.flatMap(\.steps).allSatisfy { $0.checks.isEmpty }, "final DDL observations cannot hide step checks")
        try require(
            !checks.isEmpty && Set(checks.map(\.id)).count == checks.count, "duplicate or empty final DDL observations")
        try require(checks.allSatisfy { !$0.id.isEmpty }, "empty final DDL observation name")
        try require(
            !databases.isEmpty && Set(databases).count == databases.count, "duplicate or empty final DDL databases")
    }

    func queries(transactional: Bool = false) -> [LabSQLBatch.Query] {
        checks.map {
            .init(
                name: $0.id,
                sql: "SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; "
                    + $0.selectedCheck(transactional: transactional).sql,
                preserveWhitespace: true)
        }
    }
}

extension SharedCorrectness.Run {
    func ddlFinalObservations(_ plan: DDLFinalObservations, caseID: String, prefix: String = "") throws {
        let values = try Dictionary(
            uniqueKeysWithValues: LabProfile.Role.allCases.map {
                (
                    $0,
                    try f.h.sqlBatch(f.profile.service($0), plan.queries(transactional: f.profile.transactionalTarget))
                )
            })
        for check in plan.checks {
            try assertion(prefix + check.id, caseID: caseID) {
                try Dictionary(
                    uniqueKeysWithValues: LabProfile.Role.allCases.map {
                        (
                            $0.rawValue,
                            try check.result(
                                values[$0]!, engine: f.profile.engine($0), role: $0.rawValue,
                                transactional: f.profile.transactionalTarget)
                        )
                    })
            }
        }
        for database in plan.databases {
            try assertion(prefix + "final-schema-" + database, caseID: caseID) {
                try compare(database)
            }
        }
    }
}
