import Foundation

extension SharedCorrectness.Run {
    /// Separate tables retain each ALTER result. All tables share the running
    /// applier, source write phases and batched observations on each server.
    func modifyColumns() throws {
        let parent = ModifyIndexCases.columns
        let tests = ModifyIndexCases.columnWorkflowCases
        try reporter.run(parent) {
            var observations: [String: [String: Any]] = [:]
            func check(_ test: ModifyIndexCases.Case, _ category: String, _ body: () throws -> Any) throws {
                try assertion(ModifyIndexCases.columnAssertion(test, category), caseID: parent.id) {
                    let value = try body()
                    observations[category, default: [:]][test.test.id] = value
                    return value
                }
            }
            func boundaries() throws -> [LabProfile.Role: Boundary] {
                try Dictionary(uniqueKeysWithValues: LabProfile.Role.allCases.map { ($0, try f.boundary($0)) })
            }
            func observe(_ tests: [ModifyIndexCases.Case], metadata: Bool) throws -> [LabProfile.Role: [String: String]]
            {
                let queries = tests.flatMap { test -> [LabSQLBatch.Query] in
                    var queries = metadata ? ModifyIndexCases.metadataQueries(test) : []
                    queries.append(
                        .init(name: "rows", sql: ModifyIndexCases.columnRowQuery(test), preserveWhitespace: true))
                    return queries.map {
                        .init(
                            name: test.test.id + "/" + $0.name, sql: $0.sql, preserveWhitespace: $0.preserveWhitespace)
                    }
                }
                return try Dictionary(
                    uniqueKeysWithValues: LabProfile.Role.allCases.map {
                        ($0, try f.h.sqlBatch(f.profile.service($0), queries))
                    })
            }
            let setup =
                ["CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"]
                + tests.flatMap { test in
                    ["DROP TABLE IF EXISTS demo.\(test.table)"]
                        + test.seed.components(separatedBy: "; ").filter {
                            !$0.isEmpty && !$0.hasPrefix("SET SESSION") && !$0.hasPrefix("CREATE DATABASE")
                                && !$0.hasPrefix("DROP TABLE")
                        }
                }
            _ = try sourcePhase("modify-setup", writes: [.init(id: "setup", sql: setup.joined(separator: "; "))])
            let starts = try boundaries()
            let before = try applier.latestProgress() ?? [:]
            let alters = try sourcePhase(
                "modify-alter", writes: tests.map { .init(id: $0.test.id, sql: $0.sql, checkWarnings: true) })
            let metadata = try observe(tests, metadata: true)
            var transactions = Dictionary(uniqueKeysWithValues: alters.map { ($0.write.id, [$0]) })
            for test in tests {
                try check(test, "schema-effects") {
                    var result: [String: Any] = ["source_statement": transactions[test.test.id]![0].json]
                    for role in LabProfile.Role.allCases {
                        let prefix = test.test.id + "/"
                        let values = Dictionary(
                            uniqueKeysWithValues: ["columns", "indexes", "engine"].map {
                                ($0, metadata[role]![prefix + $0]!)
                            })
                        result[role.rawValue] = try ModifyIndexCases.checkMetadata(
                            test, values: values, engine: f.profile.engine(role))
                        try require(
                            metadata[role]![prefix + "rows"] == test.retained,
                            "\(test.test.id)/\(role.rawValue): ALTER changed retained rows")
                    }
                    return result
                }
            }
            var rowEvidence: [String: [[String: Any]]] = [:]
            for ordinal in 0..<(tests.map { $0.workload.count }.max() ?? 0) {
                let selected = tests.filter { $0.workload.count > ordinal }
                let writes = try sourcePhase(
                    "modify-dml-\(ordinal + 1)",
                    writes: selected.map {
                        .init(id: $0.test.id, sql: $0.workload[ordinal].sql)
                    })
                let rows = try observe(selected, metadata: false)
                for (test, write) in zip(selected, writes) {
                    transactions[test.test.id, default: []].append(write)
                    var observed: [String: String] = [:]
                    for role in LabProfile.Role.allCases {
                        let value = rows[role]![test.test.id + "/rows"]!
                        if value != test.workload[ordinal].rows {
                            try check(test, "following-dml") {
                                throw LabError(
                                    "phase \(ordinal + 1)/\(role.rawValue): got \(value), expected \(test.workload[ordinal].rows)"
                                )
                            }
                        }
                        observed[role.rawValue] = value
                    }
                    rowEvidence[test.test.id, default: []].append(["source": write.json, "rows": observed])
                }
            }
            for test in tests {
                try check(test, "following-dml") { rowEvidence[test.test.id]! }
            }
            // One complete schema/row comparison also checks that DML did not
            // change any table definition or an unrelated table in this database.
            try writeJSON(compare("demo"), to: f.output.appendingPathComponent("modify-final-comparison.json"))
            let ends = try boundaries()
            let progress = try applier.latestProgress() ?? [:]
            for (key, expected) in [
                ("transactionsApplied", tests.count + tests.reduce(0) { $0 + $1.workload.count }),
                ("ddlApplied", tests.count),
                ("rowsApplied", tests.reduce(0) { $0 + $1.workload.reduce(0) { $0 + $1.affectedRows } }),
            ] {
                try require(
                    (progress[key] as? Int ?? 0) - (before[key] as? Int ?? 0) == expected,
                    "MODIFY phase counter differs: " + key)
            }
            try require(progress["appliedGTIDSet"] as? String == ends[.source]!.gtids, "MODIFY phase GTIDs differ")
            try applier.drain()
            let saved = try snapshot(parent.id)
            var decoded: [LabProfile.Role: String] = [:]
            for role in LabProfile.Role.allCases {
                let from = starts[role]!
                let to = ends[role]!
                try require(from.file == to.file, "unexpected rotation in MODIFY comparison")
                let file = try copyBinlog(role, file: from.file, label: parent.id)
                let text = try f.runner.run([
                    f.h.decoder, "--no-defaults", "--verify-binlog-checksum", "--base64-output=DECODE-ROWS", "-vv",
                    "--start-position=\(from.position)", "--stop-position=\(to.position)", file.path,
                ]).text
                try text.write(to: file.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                decoded[role] = text
            }
            for test in tests {
                let writes = transactions[test.test.id]!
                try check(test, "source-boundary") {
                    try ModifyIndexCases.columnBoundaries(test, writes: writes) { try state(saved, $0) }
                    return ["writes": writes.map(\.json), "phase_before": before, "phase_after": progress]
                }
                try check(test, "schema-history") {
                    try ModifyIndexCases.columnHistory(test, gtids: writes.map(\.gtids)) { try state(saved, $0) }
                }
                try check(test, "normalized-binlog") {
                    var values: [String: [String]] = [:]
                    for role in LabProfile.Role.allCases {
                        let lines = try ModifyIndexCases.columnBinlog(decoded[role]!, test: test)
                        if let source = values["source"] {
                            try require(lines == source, "\(test.test.id): normalized binlog differs: " + role.rawValue)
                        }
                        values[role.rawValue] = lines
                    }
                    return values
                }
            }
            for category in ModifyIndexCases.columnChecks {
                try assertion(category, caseID: parent.id) {
                    try ModifyIndexCases.columnEvidence(observations[category] ?? [:])
                }
            }
            try assertion("saved-state-resume", caseID: parent.id) {
                let end = ends[.source]!
                let checkpoint = try state(
                    saved, "SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
                try require(checkpoint == "STOPPED|\(end.file)|\(end.position)", "MODIFY checkpoint differs")
                try applier.start(initialize: false)
                let test = tests.last!
                let result = try sourcePhase(
                    "modify-resume",
                    writes: [.init(id: "following-update", sql: "UPDATE demo.\(test.table) SET n=10 WHERE id=1")])
                for role in LabProfile.Role.allCases {
                    try require(
                        f.sql(role, "SELECT id,n FROM demo.\(test.table) ORDER BY id") == "1\t10\n2\t8",
                        "MODIFY saved-state update differs")
                }
                savedSchemaRestartChecked = true
                return ["checkpoint": checkpoint, "following_update": result.map(\.json)]
            }
        }
    }
}

extension ModifyIndexCases {
    /// An aggregate catalog assertion passes only after every named subcase has
    /// supplied its checked observation. A passed parent alone is insufficient.
    static func columnEvidence(_ observations: [String: Any]) throws -> [String: Any] {
        try require(Set(observations.keys) == Set(columnIDs), "incomplete MODIFY column evidence")
        return observations
    }

    /// A later DROP retires earlier schemas. Check immutable schema IDs and the
    /// exact GTID interval, rather than the latest intent or the current schema.
    static func columnHistory(_ test: Case, gtids: [String], query: (String) throws -> String) throws -> [String: Any] {
        try require(!gtids.isEmpty, "MODIFY interval has no journaled GTIDs")
        let interval = gtids.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let predicate = "gtid IN (\(interval))"
        try require(
            try query("SELECT COUNT(*) FROM ddl_intents WHERE \(predicate)") == "1",
            "MODIFY interval must have one DDL intent")
        let intent = try query("SELECT status||'|'||target_sql FROM ddl_intents WHERE \(predicate)")
        try require(intent == "DONE|" + test.sql, "MODIFY DDL rewritten or incomplete")
        let schemaID = try query("SELECT after_schema_id FROM ddl_intents WHERE \(predicate)")
        guard let id = Int(schemaID) else { throw LabError("MODIFY after-schema ID is missing") }
        let raw = try query("SELECT schema_json FROM schemas WHERE id=\(id)")
        let schema = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let history = try query(
            "SELECT json_extract(value,'$.after') FROM ddl_details,json_each(transitions_json) WHERE \(predicate) AND json_extract(value,'$.after.database')='demo' AND json_extract(value,'$.after.table')='\(test.table)'"
        )
        let after = try JSONSerialization.jsonObject(with: Data(history.utf8)) as? [String: Any]
        try require(
            NSDictionary(dictionary: schema ?? [:]).isEqual(to: after ?? [:]),
            "MODIFY schema differs from its DDL transition")
        try require(
            (schema?["columns"] as? [[String: Any]])?.count == 4 && schema?["secondaryIndexes"] is [[String: Any]],
            "MODIFY schema metadata missing")
        let count = test.workload.reduce(0) { $0 + $1.affectedRows }
        try require(
            try query("SELECT COUNT(*) FROM row_intents WHERE \(predicate)") == String(count),
            "MODIFY row count differs")
        let rows = try query(
            "SELECT COUNT(*) FROM row_intents WHERE \(predicate) AND status='DONE' AND schema_id=\(id)")
        try require(rows == String(count), "MODIFY following rows did not use the completed DDL schema")
        try require(try query("PRAGMA user_version") == "14", "state version gate differs")
        return [
            "intent": intent, "gtids": gtids, "schema_id": id, "schema": schema ?? [:], "following_row_intents": rows,
        ]
    }
}

extension ModifyIndexCases {
    static var columnWorkflowCases: [Case] {
        columnCases.map { test in
            let table = test.test.id.replacingOccurrences(of: "ddl-", with: "").replacingOccurrences(of: "-", with: "_")
            func renamed(_ sql: String) -> String {
                sql.replacingOccurrences(of: "demo." + test.table, with: "demo." + table)
            }
            return Case(
                String(test.test.id.dropFirst(4)), test.test.name, seed: renamed(test.seed), sql: renamed(test.sql),
                table: table,
                columns: test.columns, indexes: test.indexes, retained: test.retained,
                workload: test.workload.map {
                    .init(sql: renamed($0.sql), rows: $0.rows, affectedRows: $0.affectedRows)
                },
                file: test.test.file, line: test.test.line)
        }
    }
    static func columnRowQuery(_ test: Case) -> String {
        "SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(test.table) ORDER BY id"
    }
    static func columnBoundaries(_ test: Case, writes: [LabSQLPhase.Result], query: (String) throws -> String) throws {
        try require(
            writes.count == 1 + test.workload.count && Set(writes.map(\.gtids)).count == writes.count,
            "MODIFY transaction boundaries are missing or repeated")
        for write in writes {
            try require(
                try DMLCompatibilityCases.transactionCount(write.gtids) == 1,
                "MODIFY statement must log one transaction")
            let gtid = write.gtids.replacingOccurrences(of: "'", with: "''")
            let actual = try query(
                "SELECT status||'|'||source_file||'|'||end_position FROM groups WHERE gtid='\(gtid)'")
            try require(
                actual == "APPLIED|\(write.end.file)|\(write.end.position)",
                "\(test.test.id): saved transaction boundary differs for \(write.gtids)")
        }
    }
    /// Keep a complete row block only when its header names this case's table.
    /// Strip mysqlbinlog's type annotations as in the standalone comparison.
    static func columnBinlog(_ decoded: String, test: Case) throws -> [String] {
        var rows = false
        var lines: [String] = []
        let table = "`demo`.`\(test.table)`"
        for raw in decoded.components(separatedBy: "\n") {
            let line = raw.range(of: " /*", options: .backwards).map { String(raw[..<$0.lowerBound]) } ?? raw
            let headers = ["### INSERT INTO ", "### UPDATE ", "### DELETE FROM "]
            if let header = headers.first(where: line.hasPrefix) { rows = line == header + table }
            if line == test.sql || (line.hasPrefix("###") && rows) { lines.append(line) }
        }
        try require(
            lines.filter { !$0.hasPrefix("###") }.count == 1, "\(test.test.id): missing or repeated ALTER in binlog")
        let count = lines.filter {
            $0.hasPrefix("### INSERT INTO") || $0.hasPrefix("### UPDATE ") || $0.hasPrefix("### DELETE FROM")
        }.count
        try require(
            count == test.workload.reduce(0) { $0 + $1.affectedRows },
            "\(test.test.id): missing or repeated rows in binlog")
        return lines
    }
}
