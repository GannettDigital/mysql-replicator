import Foundation

/// Observe each row change before a later operation can hide it. Only the state
/// snapshot and restart are shared across the selected database creation cases.
enum DatabaseCreationWorkflow {
    struct Phase {
        let id: String
        let writes: [LabSQLPhase.Write]
        let rows: String
    }

    static func phases(_ test: DatabaseCreationCases.Case, source57: Bool) -> [Phase] {
        let table = test.database + ".probe"
        // A separate mysql client previously supplied fresh server defaults for
        // each operation. USE otherdb is harmless for fully qualified tables.
        let reset = "SET SESSION collation_server=@@GLOBAL.collation_server; "
        var setup: [LabSQLPhase.Write] = [
            .init(id: "create-database", sql: reset + (source57 ? test.prefix57 : test.prefix) + test.sql)
        ]
        if !test.existing {
            setup.append(
                .init(id: "create-table", sql: reset + "CREATE TABLE \(table)(id INT PRIMARY KEY,note VARCHAR(20))"))
        }
        setup.append(
            .init(
                id: "insert",
                sql: reset + "INSERT INTO \(table) VALUES" + (test.existing ? "(2,NULL)" : "(1,'seed'),(2,NULL)")))
        return [
            .init(id: "insert", writes: setup, rows: "1\t73656564\n2\t<NULL>"),
            .init(
                id: "update",
                writes: [
                    .init(
                        id: "update",
                        sql: reset + "UPDATE \(table) SET id=3,note=CONVERT(0xF09F9880 USING utf8mb4) WHERE id=2")
                ],
                rows: "1\t73656564\n3\tF09F9880"),
            .init(
                id: "delete", writes: [.init(id: "delete", sql: reset + "DELETE FROM \(table) WHERE id=3")],
                rows: "1\t73656564"),
        ]
    }

    static func schemaQueries(_ test: DatabaseCreationCases.Case) -> [LabSQLBatch.Query] {
        [
            .init(name: "database", sql: test.metadataSQL),
            .init(
                name: "columns",
                sql:
                    "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,COLUMN_KEY,IFNULL(COLLATION_NAME,'') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe' ORDER BY ORDINAL_POSITION",
                preserveWhitespace: true),
            .init(
                name: "engine",
                sql:
                    "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe'"
            ),
        ]
    }

    static func checkSchema(_ test: DatabaseCreationCases.Case, values: [String: String], engine: String) throws {
        try require(
            values["database"] == test.expected
                && values["columns"] == "id\tint\tNO\tPRI\t\nnote\tvarchar\tYES\t\t" + test.collation
                && values["engine"] == engine,
            "\(test.test.id): database/table inheritance differs: \(values)")
    }

    static func checkWarning(_ test: DatabaseCreationCases.Case, _ warning: String) throws {
        try require(
            test.existing ? warning.hasPrefix("Note\t1007\t") : warning.isEmpty,
            "\(test.test.id): unexpected CREATE DATABASE warnings: " + warning)
    }

    static func checkJournal(
        _ test: DatabaseCreationCases.Case, writes: [LabSQLPhase.Result], query: (String) throws -> String
    ) throws {
        func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let expectedIDs = phases(test, source57: false).flatMap { $0.writes.map(\.id) }
        try require(
            writes.map { $0.write.id } == expectedIDs && Set(writes.map(\.gtids)).count == writes.count,
            "\(test.test.id): missing or repeated database source operation")
        for write in writes {
            try require(
                try DMLCompatibilityCases.transactionCount(write.gtids) == 1,
                "\(test.test.id): database operation must log one transaction")
            let gtid = literal(write.gtids)
            let actual = try query("SELECT status||'|'||source_file||'|'||end_position FROM groups WHERE gtid=\(gtid)")
            try require(
                actual == "APPLIED|\(write.end.file)|\(write.end.position)",
                "\(test.test.id)/\(write.write.id): saved transaction boundary differs: \(actual)")
        }
        let count = try query(
            "SELECT COUNT(*) FROM ddl_intents WHERE database_json IS NOT NULL AND before_schema_id IS NULL AND after_schema_id IS NULL AND status='DONE' AND target_sql=\(literal(test.sql))"
        )
        try require(count == "1", "\(test.test.id): database DDL intent differs")
    }
}

extension SharedCorrectness.Run {
    func databaseCreation() throws {
        let tests = DatabaseCreationCases.cases.filter { selects($0.test.id) }
        // Other DDL cases also use this database, including standalone ALTER
        // rename selections. Keep setup even when no creation case is selected.
        try step("CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin", database: "otherdb")
        guard !tests.isEmpty else { return }
        var transactions: [String: [LabSQLPhase.Result]] = [:]
        for test in tests {
            try reporter.run(test.test) {
                let before = try applier.latestProgress() ?? [:]
                let phases = DatabaseCreationWorkflow.phases(test, source57: f.profile.sourceVersion == .mysql57)
                var writes: [LabSQLPhase.Result] = []
                var rowObservations: [String: Any] = [:]
                func execute(_ phase: DatabaseCreationWorkflow.Phase) throws -> [LabSQLPhase.Result] {
                    let results = try sourcePhase(
                        test.test.id + "-" + phase.id, writes: phase.writes, database: test.database)
                    writes += results
                    var rows: [String: String] = [:]
                    for role in LabProfile.Role.allCases {
                        let value = try f.sql(
                            role,
                            "SELECT id,IFNULL(HEX(note),'<NULL>') FROM \(test.database).probe ORDER BY id")
                        try require(
                            value == phase.rows,
                            "\(test.test.id)/\(phase.id)/\(role.rawValue): database rows differ: \(value)")
                        rows[role.rawValue] = value
                    }
                    rowObservations[phase.id] = rows
                    return results
                }
                try assertion("schema-effects", caseID: test.test.id) {
                    let results = try execute(phases[0])
                    try DatabaseCreationWorkflow.checkWarning(test, results[0].warnings)
                    var values: [String: Any] = ["source_operations": results.map(\.json)]
                    for role in LabProfile.Role.allCases {
                        let schema = try f.h.sqlBatch(
                            f.profile.service(role), DatabaseCreationWorkflow.schemaQueries(test))
                        try DatabaseCreationWorkflow.checkSchema(test, values: schema, engine: f.profile.engine(role))
                        values[role.rawValue] = schema
                    }
                    return values
                }
                try assertion("following-dml", caseID: test.test.id) {
                    for phase in phases.dropFirst() { _ = try execute(phase) }
                    let progress = try applier.latestProgress() ?? [:]
                    for (key, count) in [
                        ("rowsApplied", test.existing ? 3 : 4),
                        ("ddlApplied", test.existing ? 1 : 2),
                        ("transactionsApplied", test.existing ? 4 : 5),
                    ] {
                        try require(
                            (progress[key] as? Int ?? 0) - (before[key] as? Int ?? 0) == count,
                            "\(test.test.id): database counter differs: " + key)
                    }
                    try require(
                        progress["appliedGTIDSet"] as? String == writes.last!.end.gtids,
                        "\(test.test.id): database GTIDs differ")
                    return [
                        "rows": rowObservations, "before": before, "after": progress,
                        "snapshots": try compare(test.database),
                    ]
                }
                transactions[test.test.id] = writes
                if test.test.id == tests.last!.test.id {
                    try assertion("creation-checkpoints", caseID: test.test.id) {
                        try applier.drain()
                        let saved = try snapshot("database-creations")
                        for item in tests {
                            try DatabaseCreationWorkflow.checkJournal(item, writes: transactions[item.test.id]!) {
                                try state(saved, $0)
                            }
                        }
                        let end = writes.last!.end
                        let checkpoint = try state(
                            saved, "SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
                        try require(checkpoint == "STOPPED|\(end.file)|\(end.position)", "database checkpoint differs")
                        try applier.start(initialize: false)
                        try wait(until: end)
                        return [
                            "checkpoint": checkpoint, "snapshot": saved.path,
                            "cases": transactions.mapValues { $0.map(\.json) },
                        ]
                    }
                }
            }
        }
    }
}
