import Foundation

/// Check predicates and restart boundaries live. Retain other states after the
/// original sequence, preserving replay stops and the keyless failure position.
enum KeyRowLifecycleWorkflows {
    static let renamedCases = [
        "ddl-compat-grouped-constraints": "ddl-alter-table-columns-constraints-and-index-names"
    ]
    struct Table {
        let name: String
        let first: Int
        var last: Int = Int.max
    }
    struct Definition {
        let prefix: String
        let steps: Int
        let restarts: [Int]
        let tables: [Table]
        var foreignKeys: [String] = []
        var dropsOriginalTables = false
    }
    struct Snapshot {
        let through: Int
        let names: [String: String]
        let tables: [String]
    }
    struct Observation {
        let step: Int
        let checks: [DDLFinalObservations.Observation]
    }
    static func observations(_ original: DDLCompatibilityCases.Case) -> [String: Observation] {
        guard definition(original.test.id) != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: original.steps.enumerated().compactMap { index, step in
            let beforeRestart = original.steps.dropFirst(index + 1).first?.restartBefore == true
            guard !step.checks.isEmpty || step.restartBefore || beforeRestart else { return nil }
            let checks = step.checks.enumerated().map {
                DDLFinalObservations.Observation(id: "original-step-\(index + 1)-check-\($0.offset + 1)", check: $0.element)
            }
            return ("original-step-\(index + 1)", .init(step: index + 1, checks: checks))
        })
    }
    static func definition(_ id: String) -> Definition? {
        switch id {
        case "ddl-compat-primary-key-parts":
            return .init(
                prefix: "pkp", steps: 11, restarts: [2, 4, 7],
                tables: [.init(name: "t", first: 1, last: 8), .init(name: "copy", first: 6),
                    .init(name: "moved", first: 9)], dropsOriginalTables: true)
        case "ddl-compat-unique-row-identity":
            return .init(
                prefix: "uri", steps: 19, restarts: [2, 7, 14],
                tables: [.init(name: "t", first: 1), .init(name: "seq", first: 16)])
        case "ddl-alter-table-columns-constraints-and-index-names":
            return .init(
                prefix: "gc", steps: 13, restarts: [4, 6, 10],
                tables: [.init(name: "p", first: 1), .init(name: "t", first: 2),
                    .init(name: "g", first: 9)], foreignKeys: ["fk"], dropsOriginalTables: true)
        default: return nil
        }
    }
    static func validateOriginal(_ original: DDLCompatibilityCases.Case) throws {
        guard let definition = definition(original.test.id) else { return }
        try require(
            original.steps.count == definition.steps && original.finalObservations == nil
                && original.steps.indices.filter { original.steps[$0].restartBefore } == definition.restarts
                && original.steps.allSatisfy { $0.phaseEnd == nil && $0.assertionID == nil && $0.transactions == 1 },
            "row/key fixture boundaries changed; review its retained states")
        for table in definition.tables {
            let sql = original.steps[table.first - 1].sql
            try require(
                sql.hasPrefix("CREATE TABLE ddlcompat." + table.name + "(")
                    || sql.hasPrefix("CREATE TABLE ddlcompat." + table.name + " ")
                    || sql.hasSuffix(" RENAME ddlcompat." + table.name),
                "row/key table lifetime changed: " + table.name)
        }
    }
    static func snapshots(_ original: DDLCompatibilityCases.Case) -> [Snapshot] {
        guard let definition = definition(original.test.id) else { return [] }
        let observed = Set(observations(original).values.map(\.step))
        return original.steps.indices.dropLast().filter { !observed.contains($0 + 1) }.map { index in
            let through = index + 1
            let names = Dictionary(uniqueKeysWithValues: definition.tables.map {
                ($0.name, "\(definition.prefix)_\(through)_\($0.name)")
            })
            return .init(
                through: through, names: names,
                tables: definition.tables.filter { $0.first <= through && through <= $0.last }.map { names[$0.name]! })
        }
    }
    static func renamed(_ sql: String, snapshot: Snapshot, definition: Definition) -> String {
        var result = snapshot.names.keys.sorted().reduce(sql) {
            KeyConstraintWorkflows.rename($0, from: $1, to: snapshot.names[$1]!)
        }
        for key in definition.foreignKeys {
            result = result.replacingOccurrences(
                of: "CONSTRAINT \(key) ", with: "CONSTRAINT \(definition.prefix)_\(snapshot.through)_\(key) ")
        }
        return result
    }
    static func plan(_ original: DDLCompatibilityCases.Case) -> DDLCompatibilityCases.Case? {
        guard let definition = definition(original.test.id) else { return nil }
        let snapshots = snapshots(original)
        let observations = observations(original)
        var steps = original.steps.enumerated().map { index, step in
            DDLCompatibilityCases.Step(
                step.sql, sqlTransactional: step.sqlTransactional, restartBefore: step.restartBefore,
                transactions: step.transactions,
                phaseEnd: observations["original-step-\(index + 1)"] != nil ? "original-step-\(index + 1)" : nil)
        }
        var checks: [DDLFinalObservations.Observation] = []
        for snapshot in snapshots {
            for step in original.steps.prefix(snapshot.through) {
                steps.append(
                    .init(
                        renamed(step.sql, snapshot: snapshot, definition: definition),
                        sqlTransactional: renamed(step.sqlTransactional, snapshot: snapshot, definition: definition),
                        transactions: step.transactions))
            }
        }
        if let last = steps.popLast() {
            steps.append(
                .init(
                    last.sql, sqlTransactional: last.sqlTransactional, restartBefore: last.restartBefore,
                    transactions: last.transactions, phaseEnd: "write-and-retain-results"))
        }
        if definition.dropsOriginalTables {
            let names = definition.tables.map { LabSQLName.sqliteLiteral($0.name) }.joined(separator: ",")
            checks.append(
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN (\(names))",
                        "0")))
        }
        // Some original cases have only a few explicit predicates. The complete
        // schema/row comparison below also covers every retained operation state.
        let tables = snapshots.flatMap(\.tables)
        let cleanupTables = snapshots.flatMap { $0.tables.reversed() }
        let names = tables.map(LabSQLName.sqliteLiteral).joined(separator: ",")
        checks.append(
            .init(
                id: "retained-state-tables",
                check: .init(
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN (\(names))",
                    String(tables.count))))
        return .init(
            String(original.test.id.dropFirst("ddl-compat-".count)), original.test.name, steps,
            nativeInnoDB: original.nativeInnoDB, profileExclusions: original.profileExclusions,
            finalObservations: .init(
                checks: checks, databases: ["ddlcompat"],
                cleanup: ["DROP TABLE " + cleanupTables.map { "ddlcompat." + $0 }.joined(separator: ",")]),
            catalogID: original.test.id, file: original.test.file, line: original.test.line)
    }
    static func schemaEvidenceSQL(_ original: DDLCompatibilityCases.Case) -> String {
        let names = snapshots(original).flatMap(\.tables).map(LabSQLName.sqliteLiteral).joined(separator: ",")
        return "SELECT COUNT(*) FROM schemas WHERE current=1 AND json_extract(schema_json,'$.database')='ddlcompat' AND json_extract(schema_json,'$.table') IN (\(names))"
    }
}

extension SharedCorrectness.Run {
    func rowKeyObservation(_ observation: KeyRowLifecycleWorkflows.Observation, caseID: String) throws {
        if !observation.checks.isEmpty {
            let queries = observation.checks.map {
                LabSQLBatch.Query(name: $0.id, sql: "SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; " + $0.check.sql,
                    preserveWhitespace: true)
            }
            let values = try Dictionary(uniqueKeysWithValues: LabProfile.Role.allCases.map {
                ($0, try f.h.sqlBatch(f.profile.service($0), queries))
            })
            for check in observation.checks {
                try assertion(check.id, caseID: caseID) {
                    try Dictionary(uniqueKeysWithValues: LabProfile.Role.allCases.map { role in
                        (role.rawValue, try check.result(values[role]!, engine: f.profile.engine(role), role: role.rawValue))
                    })
                }
            }
        }
        try assertion("original-step-\(observation.step)-schema", caseID: caseID) { try compare("ddlcompat") }
    }
}
