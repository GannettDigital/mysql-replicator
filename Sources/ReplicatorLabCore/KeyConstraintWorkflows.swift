import Foundation

/// Keep reviewed definitions and catalog assertions unchanged. Only the shared
/// runner uses these generated source steps and their retained table states.
enum KeyConstraintWorkflows {
    struct State {
        var table: String
        var assertion: String
        var rows: Int
        var affectedRows: Int
        var createMetadata: String? = nil
        var named = true
        var unlogged = false
    }
    struct Table {
        var name: String
        var steps: Range<Int>
        var states: [State]
    }
    struct Execution {
        let test: DDLCompatibilityCases.Case
        let states: [State]
        let ddl: Int
        let rows: Int
        var transactions: Int { test.steps.reduce(0) { $0 + $1.transactions } }

        func checkpoint(
            writes: [LabSQLPhase.Result], before: [String: Any], after: [String: Any],
            query: (String) throws -> String
        ) throws -> [String: Any] {
            try require(writes.count == test.steps.count, "key workflow has missing source operations")
            let unlogged = try DDLExecutionPhase(id: "key-checkpoint", steps: test.steps).validateUnlogged(writes)
            let logged = zip(test.steps, writes).filter { $0.0.transactions == 1 }.map { $0.1 }
            try require(
                !logged.isEmpty && Set(logged.map(\.gtids)).count == logged.count,
                "key workflow has missing or repeated source transactions")
            for (key, expected) in [
                ("transactionsApplied", transactions), ("ddlApplied", ddl), ("rowsApplied", rows),
            ] {
                try require(
                    (after[key] as? Int ?? 0) - (before[key] as? Int ?? 0) == expected,
                    "key workflow counter differs: " + key)
            }
            for write in logged {
                try require(
                    try DMLCompatibilityCases.transactionCount(write.gtids) == 1,
                    "key operation must log one transaction")
                let gtid = LabSQLName.sqliteLiteral(write.gtids)
                let actual = try query(
                    "SELECT status||'|'||source_file||'|'||end_position FROM groups WHERE gtid=\(gtid)")
                try require(
                    actual == "APPLIED|\(write.end.file)|\(write.end.position)",
                    "key workflow saved offset differs: " + write.write.id)
            }
            let interval = logged.map { LabSQLName.sqliteLiteral($0.gtids) }.joined(separator: ",")
            for (table, expected) in [("ddl_intents", ddl), ("row_intents", rows)] {
                let count = try query("SELECT COUNT(*) FROM \(table) WHERE gtid IN (\(interval))")
                let done = try query("SELECT COUNT(*) FROM \(table) WHERE gtid IN (\(interval)) AND status='DONE'")
                try require(
                    count == String(expected) && done == count, "key workflow has missing or unfinished " + table)
            }
            let end = writes.last!.end
            let checkpoint = try query("SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
            try require(checkpoint == "STOPPED|\(end.file)|\(end.position)", "key workflow checkpoint differs")
            for state in states {
                let count = try query(
                    "SELECT COUNT(*) FROM schemas WHERE current=1 AND json_extract(schema_json,'$.database')='ddlcompat' AND json_extract(schema_json,'$.table')=\(LabSQLName.sqliteLiteral(state.table))"
                )
                try require(count == "1", "missing or ambiguous saved key schema: " + state.table)
            }
            return [
                "writes": writes.map(\.json), "checkpoint": checkpoint, "ddl": ddl, "rows": rows,
                "tables": states.map(\.table),
                "transactions": transactions, "unloggedOperations": unlogged,
                "unloggedWrites": zip(test.steps, writes).filter { $0.0.transactions == 0 }.map { $0.1.json },
            ]
        }
    }

    static func tables(_ id: String) -> [Table]? {
        switch id {
        case "ddl-compat-primary-key-row-matching":
            return [
                .init(
                    name: "composite_key", steps: 0..<5,
                    states: [
                        .init(
                            table: "pk_composite_created", assertion: "composite-primary-key-create", rows: 0,
                            affectedRows: 0,
                            createMetadata:
                                "id:int:NO:-:-\nreport_date:date:NO:-:-\nv:varchar:YES:utf8mb4:utf8mb4_bin\nPRIMARY:0:1:report_date\nPRIMARY:0:2:id"
                        ),
                        .init(
                            table: "pk_composite_inserted", assertion: "composite-primary-key-insert", rows: 3,
                            affectedRows: 3),
                        .init(
                            table: "pk_composite_date_changed", assertion: "composite-primary-key-update-date", rows: 3,
                            affectedRows: 1),
                        .init(
                            table: "pk_composite_id_changed", assertion: "composite-primary-key-update-id", rows: 3,
                            affectedRows: 1),
                        .init(
                            table: "composite_key", assertion: "composite-primary-key-delete", rows: 2, affectedRows: 1),
                    ]),
                .init(
                    name: "text_key", steps: 5..<9,
                    states: [
                        .init(
                            table: "pk_text_created", assertion: "text-primary-key-create", rows: 0, affectedRows: 0,
                            createMetadata: "id:varchar:NO:utf8mb4:utf8mb4_unicode_ci\nv:int:YES:-:-\nPRIMARY:0:1:id"),
                        .init(
                            table: "pk_text_inserted", assertion: "text-primary-key-insert", rows: 2, affectedRows: 2),
                        .init(
                            table: "pk_text_case_changed", assertion: "text-primary-key-update-case", rows: 2,
                            affectedRows: 1),
                        .init(
                            table: "text_key", assertion: "text-primary-key-delete-case-insensitive", rows: 1,
                            affectedRows: 1),
                    ]),
            ]
        case "ddl-compat-constraints":
            return [
                .init(
                    name: "aux", steps: 0..<10,
                    states: [
                        .init(
                            table: "constraint_initial", assertion: "constraint-symbol-index-names", rows: 0,
                            affectedRows: 0, named: false),
                        .init(
                            table: "constraint_single_insert", assertion: "unique-key-single-row-insert", rows: 1,
                            affectedRows: 1, named: false),
                        .init(
                            table: "constraint_unique_dropped", assertion: "drop-named-unique-index", rows: 1,
                            affectedRows: 0, named: false),
                        .init(
                            table: "constraint_named_unique", assertion: "add-named-unique-constraint", rows: 1,
                            affectedRows: 0, named: false),
                        .init(
                            table: "constraint_multi_insert", assertion: "unique-key-multirow-insert", rows: 4,
                            affectedRows: 3, named: false),
                        .init(
                            table: "constraint_single_update", assertion: "primary-key-single-row-update", rows: 4,
                            affectedRows: 1),
                        .init(
                            table: "constraint_explicit_name", assertion: "explicit-index-name-precedence", rows: 4,
                            affectedRows: 0, named: false),
                        .init(
                            table: "constraint_unnamed_unique", assertion: "unnamed-unique-index-name", rows: 4,
                            affectedRows: 0, named: false),
                        .init(
                            table: "constraint_primary_replaced", assertion: "replace-primary-key-constraint", rows: 4,
                            affectedRows: 0, named: false),
                        .init(table: "aux", assertion: "primary-key-single-row-delete", rows: 3, affectedRows: 1),
                    ]),
                .init(
                    name: "row_values", steps: 10..<14,
                    states: [
                        .init(
                            table: "constraint_row_values_created", assertion: "primary-key-row-values-create", rows: 0,
                            affectedRows: 0,
                            createMetadata: "id:int:NO:-:-\nv:int:NO:-:-\nPRIMARY:0:1:id"),
                        .init(
                            table: "constraint_row_values_inserted", assertion: "primary-key-multirow-insert", rows: 3,
                            affectedRows: 3),
                        .init(
                            table: "constraint_row_values_updated", assertion: "primary-key-multirow-update", rows: 3,
                            affectedRows: 2),
                        .init(table: "row_values", assertion: "primary-key-multirow-delete", rows: 1, affectedRows: 2),
                    ]),
            ]
        case "ddl-compat-key-conflicts":
            let metadata = "id:int:NO:-:-\nv:int:NO:-:-\nPRIMARY:0:1:id\nuk:0:1:v"
            return [
                .init(
                    name: "insert_on_duplicate", steps: 0..<4,
                    states: [
                        .init(
                            table: "upsert_created", assertion: "upsert-table-create", rows: 0, affectedRows: 0,
                            createMetadata: metadata),
                        .init(table: "upsert_seeded", assertion: "insert-on-duplicate-seed", rows: 2, affectedRows: 2),
                        .init(table: "upsert_mixed", assertion: "insert-on-duplicate-mixed", rows: 3, affectedRows: 2),
                        .init(
                            table: "insert_on_duplicate", assertion: "insert-on-duplicate-noop", rows: 3,
                            affectedRows: 0, unlogged: true),
                    ]),
                .init(
                    name: "replace_rows", steps: 4..<7,
                    states: [
                        .init(
                            table: "replace_created", assertion: "replace-table-create", rows: 0, affectedRows: 0,
                            createMetadata: metadata),
                        .init(table: "replace_seeded", assertion: "replace-seed", rows: 2, affectedRows: 2),
                        // Native REPLACE can use an UPDATE for the last unique-key
                        // conflict. Both saved source versions log three mutations.
                        .init(
                            table: "replace_rows", assertion: "replace-primary-and-unique-conflicts", rows: 2,
                            affectedRows: 3),
                    ]),
                .init(
                    name: "insert_ignore", steps: 7..<11,
                    states: [
                        .init(
                            table: "ignore_created", assertion: "ignore-table-create", rows: 0, affectedRows: 0,
                            createMetadata: metadata),
                        .init(table: "ignore_seeded", assertion: "insert-ignore-seed", rows: 1, affectedRows: 1),
                        .init(
                            table: "ignore_mixed", assertion: "insert-ignore-mixed-conflicts", rows: 2, affectedRows: 1),
                        .init(
                            table: "insert_ignore", assertion: "insert-ignore-noop", rows: 2, affectedRows: 0,
                            unlogged: true),
                    ]),
            ]
        default: return nil
        }
    }

    /// Fixture identifiers only. Keep column/index/constraint names and values.
    static func rename(_ sql: String, from: String, to: String) -> String {
        sql.replacingOccurrences(of: "ddlcompat." + from, with: "ddlcompat." + to)
            .replacingOccurrences(of: "ALTER TABLE " + from + " ", with: "ALTER TABLE " + to + " ")
            .replacingOccurrences(of: "TABLE_NAME='" + from + "'", with: "TABLE_NAME='" + to + "'")
    }

    static func plan(_ original: DDLCompatibilityCases.Case) throws -> Execution? {
        guard let tables = tables(original.test.id) else { return nil }
        return try plan(original, tables: tables)
    }

    static func plan(_ original: DDLCompatibilityCases.Case, tables: [Table]) throws -> Execution {
        try require(original.finalObservations == nil, "key workflow already has final observations")
        let states = tables.flatMap(\.states)
        try require(
            tables.flatMap { Array($0.steps) } == Array(original.steps.indices)
                && tables.allSatisfy {
                    !$0.steps.isEmpty && $0.states.count == $0.steps.count && $0.states.last?.table == $0.name
                },
            "key workflow must retain every operation state in order")
        try require(
            Set(states.map(\.table)).count == states.count && Set(states.map(\.assertion)).count == states.count,
            "duplicate retained key table or assertion")
        try require(
            states.allSatisfy {
                $0.table.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
                    && !$0.assertion.isEmpty && $0.rows >= 0 && $0.affectedRows >= 0
            }, "invalid retained key state")
        var body: [DDLCompatibilityCases.Step] = []
        var history: [DDLCompatibilityCases.Step] = []
        var checks: [DDLFinalObservations.Observation] = []
        var ddl = 0
        var rows = 0
        func append(sql: String, changedRows: Int, transactions: Int, to steps: inout [DDLCompatibilityCases.Step]) {
            steps.append(.init(sql, transactions: transactions))
            ddl +=
                sql.hasPrefix("CREATE TABLE ") || sql.hasPrefix("ALTER TABLE ")
                    || sql.hasPrefix("USE ddlcompat; ALTER TABLE ") ? 1 : 0
            rows += changedRows
        }
        for table in tables {
            for (offset, index) in table.steps.enumerated() {
                let step = original.steps[index]
                let state = table.states[offset]
                try require(
                    step.transactions == (state.unlogged ? 0 : 1) && !step.restartBefore && step.phaseEnd == nil
                        && step.sql == step.sqlTransactional && step.checks.count <= 1,
                    "key workflow source behavior changed; review its execution plan")
                try require(
                    step.assertionID == (state.named ? state.assertion : nil),
                    "missing, unknown or changed named key assertion: " + state.assertion)
                try require(
                    step.sql.contains("ddlcompat." + table.name)
                        || step.sql.contains("ALTER TABLE " + table.name + " "),
                    "key operation does not name its declared table")
                try require(
                    state.createMetadata == nil || step.sql.hasPrefix("CREATE TABLE "),
                    "key metadata observation must follow CREATE")
                try require(
                    !state.unlogged
                        || (state.affectedRows == 0 && state.createMetadata == nil
                            && ["INSERT ", "UPDATE ", "DELETE ", "REPLACE "].contains(where: step.sql.hasPrefix)),
                    "unlogged key operation must be DML with no row mutations")
                append(sql: step.sql, changedRows: state.affectedRows, transactions: step.transactions, to: &body)
                if state.table != table.name {
                    for previous in table.steps.lowerBound...index {
                        append(
                            sql: rename(original.steps[previous].sql, from: table.name, to: state.table),
                            changedRows: table.states[previous - table.steps.lowerBound].affectedRows,
                            transactions: original.steps[previous].transactions, to: &history)
                    }
                }
                let check: DDLCompatibilityCases.Check
                if let old = step.checks.first {
                    check = .init(
                        rename(old.sql, from: table.name, to: state.table), old.expected, fields: old.fields,
                        myISAMExpected: old.myISAMExpected)
                } else {
                    let count = "SELECT COUNT(*) FROM ddlcompat." + state.table
                    if let metadata = state.createMetadata {
                        try require(
                            step.sql.hasPrefix("CREATE TABLE ") && state.rows == 0,
                            "CREATE key observation must check an empty table")
                        let condition = "TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='\(state.table)'"
                        check = .init(
                            count
                                + "; SELECT CONCAT_WS(':',COLUMN_NAME,DATA_TYPE,IS_NULLABLE,IFNULL(CHARACTER_SET_NAME,'-'),IFNULL(COLLATION_NAME,'-')) FROM information_schema.COLUMNS WHERE \(condition) ORDER BY ORDINAL_POSITION; SELECT CONCAT_WS(':',INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME) FROM information_schema.STATISTICS WHERE \(condition) ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                            "0\n" + metadata)
                    } else {
                        try require(!step.sql.hasPrefix("CREATE TABLE "), "missing CREATE key metadata observation")
                        check = .init(count, String(state.rows))
                    }
                }
                checks.append(.init(id: state.assertion, check: check))
            }
        }
        func end(_ steps: inout [DDLCompatibilityCases.Step], _ id: String) {
            let last = steps.removeLast()
            steps.append(.init(last.sql, transactions: last.transactions, phaseEnd: id))
        }
        try require(!body.isEmpty && !history.isEmpty, "empty retained key workflow")
        end(&body, "key-changes")
        end(&history, "retain-key-states")
        let final = DDLFinalObservations(checks: checks, databases: ["ddlcompat"], cleanup: [])
        let test = DDLCompatibilityCases.Case(
            String(original.test.id.dropFirst("ddl-compat-".count)), original.test.name, body + history,
            nativeInnoDB: original.nativeInnoDB, profileExclusions: original.profileExclusions,
            finalObservations: final, file: original.test.file, line: original.test.line)
        try final.validate(DDLExecutionPhase.plan(test.steps) ?? [])
        return .init(test: test, states: states, ddl: ddl, rows: rows)
    }
}
