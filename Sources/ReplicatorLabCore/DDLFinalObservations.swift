import Foundation

/// Independent table sets retain ordinary results until one final query batch.
/// Cleanup follows the case's saved-state assertions, before the next case.
struct DDLFinalObservations {
    struct Observation {
        let id: String
        let check: DDLCompatibilityCases.Check

        func result(_ values: [String: String], engine: String, role: String) throws -> [String: Any] {
            guard let value = values[id] else { throw LabError("\(id)/\(role): missing final observation") }
            let expected = check.expected(engine: engine)
            try require(
                LabSQLName.equal(check.observation(value), expected),
                "\(id)/\(role): \(check.sql) got \(value), expected \(expected)")
            return ["query": check.sql, "value": value, "expected": expected, "fields": check.fields ?? []]
        }
    }
    let checks: [Observation]
    let databases: [String]
    let cleanup: [String]

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

    var queries: [LabSQLBatch.Query] {
        checks.map {
            .init(
                name: $0.id, sql: "SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; " + $0.check.sql,
                preserveWhitespace: true)
        }
    }
}

extension SharedCorrectness.Run {
    func ddlFinalObservations(_ plan: DDLFinalObservations, caseID: String) throws {
        let values = try Dictionary(
            uniqueKeysWithValues: LabProfile.Role.allCases.map {
                ($0, try f.h.sqlBatch(f.profile.service($0), plan.queries))
            })
        for check in plan.checks {
            try assertion(check.id, caseID: caseID) {
                try Dictionary(
                    uniqueKeysWithValues: LabProfile.Role.allCases.map {
                        ($0.rawValue, try check.result(values[$0]!, engine: f.profile.engine($0), role: $0.rawValue))
                    })
            }
        }
        for database in plan.databases {
            try assertion("final-schema-" + database, caseID: caseID) {
                try compare(database)
            }
        }
    }
}
