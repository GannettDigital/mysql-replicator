import Foundation

extension ModifyIndexCases {
    static func indexTableMap(_ test: Case) -> [String: String] {
        let prefix = String(test.test.id.dropFirst(4)).replacingOccurrences(of: "-", with: "_")
        return ["mi": prefix, "mi_clone": prefix + "_copy", "mi_renamed": prefix + "_renamed"]
    }

    static var indexWorkflowCases: [Case] {
        standaloneCases.map { test in
            let names = indexTableMap(test)
            func renamed(_ sql: String) -> String {
                names.keys.sorted { $0.count > $1.count }.reduce(sql) {
                    $0.replacingOccurrences(of: "demo." + $1, with: "demo." + names[$1]!)
                }
            }
            return Case(
                String(test.test.id.dropFirst(4)), test.test.name,
                seed: renamed(test.seed), sql: renamed(test.sql), table: names[test.table]!,
                columns: test.columns, indexes: test.indexes, retained: test.retained,
                workload: test.workload.map {
                    .init(sql: renamed($0.sql), rows: $0.rows, affectedRows: $0.affectedRows)
                }, file: test.test.file, line: test.test.line)
        }
    }

    static func indexSetup(_ tests: [Case]) -> String {
        ([
            "CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
            "DROP TABLE IF EXISTS demo.explicit_default_engine",
        ]
            + tests.flatMap { test in
                // Keep single-table DROP statements. Compound DROP has its own case.
                indexTableMap(test).values.sorted().map { "DROP TABLE IF EXISTS demo." + $0 }
                    + test.seed.components(separatedBy: "; ").filter {
                        !$0.isEmpty && !$0.hasPrefix("SET SESSION") && !$0.hasPrefix("CREATE DATABASE")
                            && !$0.hasPrefix("DROP TABLE")
                    }
            }).joined(separator: "; ")
    }
}

extension SharedCorrectness.Run {
    /// Preserve the selected case IDs. The first case owns shared execution time;
    /// batched SQL records all participating IDs and names each logical query.
    func indexOperations() throws {
        let tests = ModifyIndexCases.indexWorkflowCases.filter { selects($0.test.id) }
        guard let first = tests.first else { return }
        let previous = f.h.sqlTrace.metadata
        f.h.sqlTrace.metadata["workflow_id"] = "index-operations"
        f.h.sqlTrace.metadata["shared_case_ids"] = tests.map { $0.test.id }
        defer { f.h.sqlTrace.metadata = previous }
        var verify: ((ModifyIndexCases.Case) throws -> Void)!
        try reporter.run(first.test) {
            func boundaries() throws -> [LabProfile.Role: Boundary] {
                try Dictionary(uniqueKeysWithValues: LabProfile.Role.allCases.map { ($0, try f.boundary($0)) })
            }
            func observe(_ selected: [ModifyIndexCases.Case], metadata: Bool) throws -> [LabProfile.Role: [String:
                String]]
            {
                let queries = selected.flatMap { test -> [LabSQLBatch.Query] in
                    let queries =
                        (metadata ? ModifyIndexCases.metadataQueries(test) : [])
                        + [.init(name: "rows", sql: ModifyIndexCases.columnRowQuery(test), preserveWhitespace: true)]
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
            _ = try sourcePhase("index-setup", writes: [.init(id: "setup", sql: ModifyIndexCases.indexSetup(tests))])
            let starts = try boundaries()
            let before = try applier.latestProgress() ?? [:]
            let ddl = try sourcePhase(
                "index-ddl", writes: tests.map { .init(id: $0.test.id, sql: $0.sql, checkWarnings: true) })
            let metadata = try observe(tests, metadata: true)
            var transactions = Dictionary(uniqueKeysWithValues: ddl.map { ($0.write.id, [$0]) })
            var rowEvidence: [String: [[String: Any]]] = [:]
            for ordinal in 0..<(tests.map { $0.workload.count }.max() ?? 0) {
                let selected = tests.filter { $0.workload.count > ordinal }
                let writes = try sourcePhase(
                    "index-dml-\(ordinal + 1)",
                    writes: selected.map {
                        .init(id: $0.test.id, sql: $0.workload[ordinal].sql)
                    })
                let rows = try observe(selected, metadata: false)
                for (test, write) in zip(selected, writes) {
                    transactions[test.test.id, default: []].append(write)
                    let values = Dictionary(
                        uniqueKeysWithValues: LabProfile.Role.allCases.map {
                            ($0.rawValue, rows[$0]![test.test.id + "/rows"]!)
                        })
                    rowEvidence[test.test.id, default: []].append(["source": write.json, "rows": values])
                }
            }
            try writeJSON(compare("demo"), to: f.output.appendingPathComponent("index-final-comparison.json"))
            let ends = try boundaries()
            let progress = try applier.latestProgress() ?? [:]
            try applier.drain()
            let saved = try snapshot("index-operations")
            var decoded: [LabProfile.Role: String] = [:]
            for role in LabProfile.Role.allCases {
                let from = starts[role]!
                let to = ends[role]!
                try require(from.file == to.file, "unexpected rotation in index comparison")
                let file = try copyBinlog(role, file: from.file, label: "index-operations")
                let text = try f.runner.run([
                    f.h.decoder, "--no-defaults", "--verify-binlog-checksum", "--base64-output=DECODE-ROWS", "-vv",
                    "--start-position=\(from.position)", "--stop-position=\(to.position)", file.path,
                ]).text
                try text.write(to: file.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                decoded[role] = text
            }
            verify = { test in
                try self.assertion("schema-effects", caseID: test.test.id) {
                    var result: [String: Any] = ["source_statement": transactions[test.test.id]![0].json]
                    for role in LabProfile.Role.allCases {
                        let prefix = test.test.id + "/"
                        let values = Dictionary(
                            uniqueKeysWithValues: ["columns", "indexes", "engine"].map {
                                ($0, metadata[role]![prefix + $0]!)
                            })
                        result[role.rawValue] = try ModifyIndexCases.checkMetadata(
                            test, values: values, engine: self.f.profile.engine(role))
                        try require(
                            metadata[role]![prefix + "rows"] == test.retained,
                            "\(test.test.id)/\(role.rawValue): DDL changed retained rows")
                    }
                    return result
                }
                if !test.workload.isEmpty {
                    try self.assertion("following-dml", caseID: test.test.id) {
                        let observations = rowEvidence[test.test.id] ?? []
                        try require(observations.count == test.workload.count, "missing index DML observations")
                        for (item, observed) in zip(test.workload, observations) {
                            let rows = observed["rows"] as! [String: String]
                            for role in LabProfile.Role.allCases {
                                try require(
                                    rows[role.rawValue] == item.rows,
                                    "\(test.test.id)/\(role.rawValue): following rows differ: \(rows[role.rawValue] ?? "missing")"
                                )
                            }
                        }
                        return observations
                    }
                }
                let writes = transactions[test.test.id]!
                try self.assertion("source-boundary", caseID: test.test.id) {
                    try ModifyIndexCases.columnBoundaries(test, writes: writes) { try self.state(saved, $0) }
                    for (key, expected) in [
                        ("transactionsApplied", tests.count + tests.reduce(0) { $0 + $1.workload.count }),
                        ("ddlApplied", tests.count),
                        ("rowsApplied", tests.reduce(0) { $0 + $1.workload.reduce(0) { $0 + $1.affectedRows } }),
                    ] {
                        try require(
                            (progress[key] as? Int ?? 0) - (before[key] as? Int ?? 0) == expected,
                            "index counter differs: " + key)
                    }
                    let end = ends[.source]!
                    try require(progress["appliedGTIDSet"] as? String == end.gtids, "index GTIDs differ")
                    let checkpoint = try self.state(
                        saved, "SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
                    try require(checkpoint == "STOPPED|\(end.file)|\(end.position)", "index checkpoint differs")
                    return [
                        "writes": writes.map(\.json), "phase_before": before, "phase_after": progress,
                        "checkpoint": checkpoint,
                    ]
                }
                try self.assertion("schema-history", caseID: test.test.id) {
                    try ModifyIndexCases.workflowHistory(test, gtids: writes.map(\.gtids), published: true) {
                        try self.state(saved, $0)
                    }
                }
                try self.assertion("normalized-binlog", caseID: test.test.id) {
                    var values: [String: [String]] = [:]
                    for role in LabProfile.Role.allCases {
                        let lines = try ModifyIndexCases.columnBinlog(
                            decoded[role]!, test: test, tables: Set(ModifyIndexCases.indexTableMap(test).values))
                        if let source = values["source"] {
                            try require(lines == source, "\(test.test.id): normalized binlog differs: " + role.rawValue)
                        }
                        values[role.rawValue] = lines
                    }
                    return values
                }
            }
            try verify(first)
            try assertion("saved-state-resume", caseID: first.test.id) {
                try applier.start(initialize: false)
                // LIKE and TRUNCATE retain no seed row. Select the first final
                // row from the fixed oracle, rather than assuming id=1 exists.
                var rows = (first.workload.last?.rows ?? first.retained).components(separatedBy: "\n").map {
                    $0.components(separatedBy: "\t")
                }
                let id = rows[0][0]
                rows[0][2] = "10"
                let writes = try sourcePhase(
                    "index-resume",
                    writes: [.init(id: first.test.id, sql: "UPDATE demo.\(first.table) SET n=10 WHERE id=\(id)")])
                let expected = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                for role in LabProfile.Role.allCases {
                    try require(
                        f.sql(role, ModifyIndexCases.columnRowQuery(first), preserveWhitespace: true) == expected,
                        "index saved-state rows differ: " + role.rawValue)
                }
                savedSchemaRestartChecked = true
                return ["following_update": writes.map(\.json)]
            }
        }
        for test in tests.dropFirst() { try reporter.run(test.test) { try verify(test) } }
    }
}
