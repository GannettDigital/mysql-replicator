import Foundation

extension SharedCorrectness.Run {
    func tableMetadataDiscovery() throws {
        for test in [MetadataDiscoveryCases.columns, MetadataDiscoveryCases.encodings] where selects(test.id) {
            try reporter.run(test) {
                try resetNativeEngine()
                try f.awaitNative()
                let fixtures = MetadataDiscoveryCases.fixtures(test.id, profile: f.profile)
                for role in LabProfile.Role.allCases {
                    _ = try f.sql(
                        role,
                        "SET sql_log_bin=0; DROP DATABASE IF EXISTS poc; CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
                    )
                    for fixture in fixtures {
                        _ = try f.sql(
                            role,
                            f.profile.session(role)
                                + "USE poc; SET sql_log_bin=0; CREATE TABLE matrix_\(fixture.id)(\(fixture.definition)) ENGINE=\(f.profile.engine(role)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin; "
                                + fixture.setup)
                    }
                }
                var rowMetadata = f.variant.metadata
                defer {
                    if f.profile.hasOptionalMetadata {
                        _ = try? f.sql(.source, "SET GLOBAL binlog_row_metadata=" + f.variant.metadata)
                    }
                }
                let start = try f.boundary()
                // A single initial INSERT makes each table enter the cache.
                // UPDATE/DELETE/ALTER value phases run with their DML owners.
                for fixture in fixtures {
                    // Retain the original TABLE_MAP variant for each definition.
                    // Only ENUM/SET fixtures override MINIMAL with FULL on 8.4.
                    let required = fixture.rowMetadata ?? f.variant.metadata
                    if f.profile.hasOptionalMetadata && rowMetadata != required {
                        _ = try f.sql(.source, "SET GLOBAL binlog_row_metadata=" + required)
                        rowMetadata = required
                    }
                    _ = try f.sql(.source, session + "USE poc; " + fixture.phases[0].sql)
                }
                let end = try f.boundary()
                let count = try DMLCompatibilityCases.transactionCount(
                    f.sql(.source, "SELECT GTID_SUBTRACT('\(end.gtids)','\(start.gtids)')"))
                let isolated = LabIsolatedApply(f)
                let config = isolated.configuration(test.id, at: start, count: count)
                let client = try isolated.start(test.id, config: config)
                let result = try isolated.finish(client, label: test.id, config: config)
                try f.awaitNative()
                let saved = try metadataSchemas(isolated, label: test.id)
                for fixture in fixtures {
                    try assertion("metadata-" + fixture.id, caseID: test.id) {
                        guard let schema = saved.first(where: { $0["table"] as? String == "matrix_" + fixture.id })
                        else {
                            throw LabError("missing saved schema: " + fixture.id)
                        }
                        let observed = try checkSavedMetadata(schema, table: "matrix_" + fixture.id)
                        for role in LabProfile.Role.allCases {
                            try require(
                                f.sql(role, f.profile.session(role) + "USE poc; " + fixture.phases[0].check) == "1",
                                "initial row/default check failed: \(fixture.id)/\(role)")
                        }
                        try checkEncodedMetadata(schema, fixture: fixture.id)
                        return [
                            "schema": schema, "information_schema": observed,
                            "initial_row_check": fixture.phases[0].check,
                        ]
                    }
                }
                try assertion("cold-reads-once", caseID: test.id) {
                    let reads = try metadataReadCount(result)
                    try require(
                        reads == fixtures.count,
                        "each existing table must have one cold schema read: \(reads)/\(fixtures.count)")
                    return ["reads": reads, "tables": fixtures.map(\.id)]
                }
                try assertion("saved-checkpoint", caseID: test.id) {
                    let actual = try isolated.state(
                        test.id, "SELECT lifecycle||'|'||transactions_applied||'|'||applied_position FROM state")
                    try require(actual == "STOPPED|\(count)|\(end.position)", "metadata checkpoint differs")
                    try require(result["appliedGTIDSet"] as? String == end.gtids, "metadata GTID checkpoint differs")
                    return ["state": actual, "source": end.json]
                }
            }
        }
        try metadataCacheDDL()
    }

    private func metadataSchemas(_ isolated: LabIsolatedApply, label: String) throws -> [[String: Any]] {
        try isolated.state(label, "SELECT schema_json FROM schemas WHERE current=1 ORDER BY identity").split(
            separator: "\n"
        ).map {
            guard let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw LabError("invalid saved schema JSON")
            }
            return value
        }
    }

    /// Compare durable fields with the server, independently of the applier's
    /// schema reader. Native display widths and binary ENUM presentation differ.
    private func checkSavedMetadata(_ schema: [String: Any], table: String) throws -> [[String: Any]] {
        let text = try f.sql(
            .target,
            "SELECT JSON_OBJECT('name',COLUMN_NAME,'type',COLUMN_TYPE,'nullable',IS_NULLABLE,'charset',CHARACTER_SET_NAME,'collation',COLLATION_NAME,'extra',EXTRA,'expression',GENERATION_EXPRESSION) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='\(table)' ORDER BY ORDINAL_POSITION",
            preserveWhitespace: true)
        let native = try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        guard let columns = schema["columns"] as? [[String: Any]] else { throw LabError("missing saved columns") }
        try require(columns.count == native.count && !columns.isEmpty, "saved column count differs: " + table)
        for (column, expected) in zip(columns, native) {
            let name = expected["name"] as! String
            let type = expected["type"] as! String
            try require(
                Data((column["name"] as? String ?? "").utf8) == Data(name.utf8),
                "saved column order/name differs: " + table)
            try require(
                column["nullable"] as? Bool == (expected["nullable"] as? String == "YES"),
                "saved nullability differs: \(table).\(name)")
            let choice = type.hasPrefix("enum(") || type.hasPrefix("set(")
            if choice {
                try require(
                    (column["type"] as? String ?? "").hasPrefix(type.hasPrefix("enum(") ? "enum(" : "set("),
                    "missing saved ENUM/SET type")
            } else {
                var normalized = type
                if !type.hasSuffix(" zerofill") {
                    normalized = type.replacingOccurrences(
                        of: #"^(tinyint|smallint|mediumint|int|bigint|year)\([0-9]+\)"#, with: "$1",
                        options: .regularExpression)
                }
                if normalized == "geomcollection" { normalized = "geometrycollection" }
                try require(
                    column["type"] as? String == normalized,
                    "saved type differs: \(table).\(name): \(column["type"] ?? "nil") != \(normalized)")
            }
            let binaryChoice =
                choice && (expected["collation"] is NSNull || expected["collation"] as? String == "binary")
            try require(
                column["characterSet"] as? String == (binaryChoice ? "binary" : expected["charset"] as? String),
                "saved charset differs: \(table).\(name)")
            try require(
                column["collation"] as? String == (binaryChoice ? "binary" : expected["collation"] as? String),
                "saved collation differs: \(table).\(name)")
            if !(expected["expression"] as? String ?? "").isEmpty {
                func compact(_ value: String) -> String {
                    value.replacingOccurrences(of: "`", with: "").filter { !$0.isWhitespace }
                }
                try require(
                    compact(column["generationExpression"] as? String ?? "")
                        == compact(expected["expression"] as? String ?? ""), "saved generated expression differs")
            }
            if (expected["extra"] as? String ?? "").contains("auto_increment") {
                try require(
                    (column["extra"] as? String ?? "").contains("auto_increment"), "missing AUTO_INCREMENT metadata")
            }
        }
        let keys = try f.sql(
            .target,
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='\(table)' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX"
        ).split(separator: "\n").map(String.init)
        try require(
            (schema["primaryKeyColumns"] as? [String] ?? (schema["primaryKey"] as? String).map { [$0] } ?? []) == keys,
            "saved primary key order differs: " + table)
        let indexes = try f.sql(
            .target,
            "SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='\(table)' AND INDEX_NAME!='PRIMARY' ORDER BY INDEX_NAME"
        ).split(separator: "\n").map(String.init)
        let savedIndexes = (schema["secondaryIndexes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            .sorted()
        try require(
            savedIndexes.map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
                == indexes.map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) },
            "saved secondary indexes differ: " + table)
        let parts = try f.sql(
            .target,
            "SELECT INDEX_NAME,COLUMN_NAME,IFNULL(SUB_PART,0),NON_UNIQUE,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='\(table)' AND INDEX_NAME!='PRIMARY' ORDER BY INDEX_NAME,SEQ_IN_INDEX"
        ).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        for index in schema["secondaryIndexes"] as? [[String: Any]] ?? [] {
            let expected = parts.filter { Data($0[0].utf8) == Data((index["name"] as? String ?? "").utf8) }
            let actual = index["parts"] as? [[String: Any]] ?? []
            try require(actual.count == expected.count && !actual.isEmpty, "saved index parts differ")
            try require(
                index["unique"] as? Bool == (expected[0][3] == "0") && index["type"] as? String == expected[0][4],
                "saved index kind differs")
            for (part, nativePart) in zip(actual, expected) {
                try require(
                    Data((part["column"] as? String ?? "").utf8) == Data(nativePart[1].utf8),
                    "saved index column order differs")
                // MySQL reports a 32-byte internal MBR prefix for spatial keys.
                if nativePart[4] != "SPATIAL" {
                    try require((part["prefix"] as? Int ?? 0) == Int(nativePart[2]), "saved index prefix differs")
                }
            }
            if index["type"] as? String == "FULLTEXT" {
                try require(index["parser"] as? String == "ngram", "saved FULLTEXT parser differs")
            }
        }
        return native
    }

    private func checkEncodedMetadata(_ schema: [String: Any], fixture: String) throws {
        let columns = schema["columns"] as! [[String: Any]]
        func column(_ name: String) throws -> [String: Any] {
            guard let value = columns.first(where: { $0["name"] as? String == name }) else {
                throw LabError("missing column " + name)
            }
            return value
        }
        func labels(_ name: String, _ hex: [String]) throws {
            // BMP UTF-8 labels use the SQL type representation. Other encodings
            // and supplementary characters retain exact byte arrays.
            if try column(name)["choiceLabels"] == nil {
                let literals = try hex.map { bytes -> String in
                    var data = Data()
                    var index = bytes.startIndex
                    while index < bytes.endIndex {
                        let next = bytes.index(index, offsetBy: 2)
                        guard let byte = UInt8(bytes[index..<next], radix: 16) else {
                            throw LabError("invalid expected label")
                        }
                        data.append(byte)
                        index = next
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw LabError("missing exact non-UTF-8 labels")
                    }
                    return "'"
                        + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
                        + "'"
                }
                let type = try column(name)["type"] as? String ?? ""
                let base = type.hasPrefix("enum(") ? "enum" : "set"
                try require(
                    type == base + "(" + literals.joined(separator: ",") + ")",
                    "saved UTF-8 labels differ: \(fixture).\(name)")
                return
            }
            let actual = try (column(name)["choiceLabels"] as? [String] ?? []).map { value -> String in
                guard let data = Data(base64Encoded: value) else { throw LabError("invalid label bytes") }
                return data.map { String(format: "%02X", $0) }.joined()
            }
            try require(actual == hex, "saved label bytes/order differ: \(fixture).\(name)")
        }
        func value(_ name: String, _ field: String, _ expected: String) throws {
            try require(column(name)[field] as? String == expected, "saved \(field) differs: \(fixture).\(name)")
        }
        switch fixture {
        case "exactchoices":
            try labels("id", ["F09F9880", "3F", "61"])
            try labels("e", ["E9", "FF"])
            try labels("w", ["2020", "4E2D"])
            try value("n", "defaultValue", "a")
            try value("q", "defaultValue", "2")
            try require(column("e")["choiceDefaultOrdinal"] as? Int == 1, "non-UTF-8 default ordinal differs")
        case "binarychoices":
            try labels("e", ["FF", "61", ""])
            try labels("s", ["41", "61"])
        case "legacybinaryset": try labels("s", ["FF", "61"])
        case "choiceboundaries":
            try labels("e", ["", "61", "69742773", "615C62"])
            try labels("w", ["2020", "2D4E"])
            try labels("s", ["00002020", "00004E2D"])
            try labels("g", ["9439FC36", "3F"])
        case "widechoices":
            try value("e", "type", "enum(" + (1...256).map { "'e\($0)'" }.joined(separator: ",") + ")")
            try value("s", "type", "set(" + (1...64).map { "'s\($0)'" }.joined(separator: ",") + ")")
        case "binarydefaults":
            try value("b", "binaryDefaultBytes", Data([255, 0, 1, 0, 0]).base64EncodedString())
            try value("v", "binaryDefaultBytes", Data([255, 0, 1]).base64EncodedString())
            try value("z", "defaultValue", "")
        case "textdefaults":
            try value("c", "defaultValue", "😀")
            try value("v", "defaultValue", "😀  ")
            try value("l", "defaultValue", "ÿ\0")
            try value("w", "defaultValue", "中")
            try value("d", "defaultValue", "e\u{0301}")
        case "decimaldefaults":
            try value("a", "defaultValue", "1.24")
            try value("b", "defaultValue", "-1.24")
        default: break
        }
    }

    private func metadataReadCount(_ progress: [String: Any]) throws -> Int {
        if let count = progress["schemaReads"] as? Int { return count }
        guard
            let count = (progress["stageTimings"] as? [String: [String: Any]])?["apply.detail.target.read_schema"]?[
                "count"] as? Int
        else { throw LabError("missing schema-read counter") }
        return count
    }

    private func metadataCacheDDL() throws {
        let test = MetadataDiscoveryCases.cache
        guard selects(test.id) else { return }
        try reporter.run(test) {
            try resetNativeEngine()
            try f.awaitNative()
            for role in LabProfile.Role.allCases {
                _ = try f.sql(
                    role,
                    "SET sql_log_bin=0; DROP DATABASE IF EXISTS poc; CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE poc.cached(id INT PRIMARY KEY,v INT) ENGINE=\(f.profile.engine(role))"
                )
            }
            let isolated = LabIsolatedApply(f)
            let config = try isolated.configuration(test.id, at: f.boundary(), count: 10)
            let priorLogging = try f.sql(.target, "SELECT @@GLOBAL.general_log")
            let priorOutput = try f.sql(.target, "SELECT @@GLOBAL.log_output")
            try require(
                ["0", "1"].contains(priorLogging)
                    && priorOutput.split(separator: ",").allSatisfy { ["FILE", "TABLE", "NONE"].contains(String($0)) },
                "invalid general query log settings")
            _ = try f.sql(
                .target, "SET GLOBAL general_log=OFF; SET GLOBAL log_output='TABLE'; SET GLOBAL general_log=ON")
            defer {
                _ = try? f.sql(
                    .target,
                    "SET GLOBAL general_log=OFF; SET GLOBAL log_output='\(priorOutput)'; SET GLOBAL general_log=\(priorLogging)"
                )
            }
            let client = try isolated.start(test.id, config: config, verbose: true)
            func write(_ sql: String, count: Int) throws -> [String: Any] {
                _ = try f.sql(.source, session + sql)
                try isolated.barrier(client, count: count)
                let logs = try f.docker(["logs", client])
                guard let progress = try LabProgress.latest(in: logs.stdout) else {
                    throw LabError("missing metadata progress")
                }
                let reads = try MetadataDiscoveryCases.schemaReadRecords(logs.stderr)
                let queries = try f.sql(
                    .target,
                    "SELECT COUNT(*) FROM mysql.general_log WHERE SUBSTRING_INDEX(user_host,'[',1)='apply_fixture' AND command_type IN ('Query','Execute') AND UPPER(CONVERT(argument USING utf8mb4)) LIKE '%INFORMATION_SCHEMA%'"
                )
                guard let total = Int(queries), total > 0 else {
                    let diagnostic = try f.sql(
                        .target,
                        "SELECT user_host,command_type,CONVERT(argument USING utf8mb4) FROM mysql.general_log ORDER BY event_time"
                    )
                    try diagnostic.write(
                        to: f.output.appendingPathComponent("metadata-query-log.tsv"), atomically: true,
                        encoding: .utf8)
                    throw LabError("missing general query log metadata records")
                }
                let observation: [String: Any] = [
                    "progress": progress, "schemaReads": reads.count, "readRecords": reads, "metadataQueries": total,
                ]
                try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
                    .write(to: f.output.appendingPathComponent("metadata-observation-\(count).json"))
                return observation
            }
            let cold = try write("INSERT INTO poc.cached VALUES(1,10)", count: 1)
            try assertion("cold-read", caseID: test.id) {
                try require(metadataReadCount(cold) == 1, "initial row did not read exactly one schema")
                return cold
            }
            let warm = try write("INSERT INTO poc.cached VALUES(2,20)", count: 2)
            try assertion("warm-cache", caseID: test.id) {
                try require(metadataReadCount(warm) == metadataReadCount(cold), "warm row repeated a schema read")
                try require(
                    warm["metadataQueries"] as? Int == cold["metadataQueries"] as? Int,
                    "warm row repeated INFORMATION_SCHEMA queries")
                return ["cold": cold, "warm": warm]
            }
            let altered = try write("ALTER TABLE poc.cached ADD extra VARCHAR(12) DEFAULT 'new'", count: 3)
            let updated = try write("UPDATE poc.cached SET extra='changed' WHERE id=1", count: 4)
            // DDL invalidates the DML plan too. The first following write may
            // validate that plan; the next write must reuse it and the schema.
            let reused = try write("UPDATE poc.cached SET v=21 WHERE id=2", count: 5)
            try assertion("alter-refresh", caseID: test.id) {
                try require(metadataReadCount(altered) > metadataReadCount(warm), "ALTER did not refresh metadata")
                try require(
                    metadataReadCount(updated) == metadataReadCount(altered),
                    "post-ALTER write repeated the refreshed schema read")
                try require(
                    (altered["metadataQueries"] as! Int) > (warm["metadataQueries"] as! Int),
                    "ALTER did not issue metadata queries")
                try require(
                    reused["metadataQueries"] as? Int == updated["metadataQueries"] as? Int
                        && metadataReadCount(reused) == metadataReadCount(updated),
                    "second post-ALTER write repeated metadata queries")
                try f.awaitNative()
                for role in LabProfile.Role.allCases {
                    try require(
                        f.sql(role, "SELECT GROUP_CONCAT(CONCAT(id,':',extra) ORDER BY id) FROM poc.cached")
                            == "1:changed,2:new", "ALTER/default or following row differs")
                }
                return ["after_alter": altered, "after_first_write": updated, "after_second_write": reused]
            }
            _ = try write("RENAME TABLE poc.cached TO poc.renamed", count: 6)
            _ = try write("UPDATE poc.renamed SET extra='renamed' WHERE id=2", count: 7)
            _ = try write("DROP TABLE poc.renamed", count: 8)
            _ = try write("CREATE TABLE poc.cached(id INT PRIMARY KEY,v VARCHAR(20))", count: 9)
            _ = try f.sql(.source, session + "INSERT INTO poc.cached VALUES(3,'different type')")
            let finished = try isolated.finish(client, label: test.id, config: config)
            try assertion("rename-drop-recreate", caseID: test.id) {
                try f.awaitNative()
                for role in LabProfile.Role.allCases {
                    try require(
                        f.sql(role, "SELECT CONCAT(id,':',v) FROM poc.cached") == "3:different type",
                        "recreated table used stale metadata")
                    try require(
                        f.sql(
                            role,
                            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='renamed'"
                        ) == "0", "renamed table remains after DROP")
                }
                let saved = try metadataSchemas(isolated, label: test.id)
                try require(
                    saved.count == 1 && saved[0]["table"] as? String == "cached", "retired table schema remains current"
                )
                _ = try checkSavedMetadata(saved[0], table: "cached")
                return ["schemas": saved, "summary": finished]
            }
            var resume = config
            var source = resume["source"] as! [String: Any]
            source["stopAfterTransactions"] = 1
            resume["source"] = source
            _ = try f.sql(.source, session + "UPDATE poc.cached SET v='resumed' WHERE id=3")
            let resumedClient = try isolated.start(test.id + "-resume", config: resume, initialize: false)
            let resumed = try isolated.finish(resumedClient, label: test.id + "-resume", config: resume)
            try assertion("saved-state-resume", caseID: test.id) {
                try f.awaitNative()
                for role in LabProfile.Role.allCases {
                    try require(
                        f.sql(role, "SELECT v FROM poc.cached WHERE id=3") == "resumed", "saved schema resume differs")
                }
                try require(
                    resumed["transactionsApplied"] as? Int == 11
                        && resumed["appliedGTIDSet"] as? String == f.boundary().gtids, "resumed checkpoint differs")
                return resumed
            }
        }
    }
}
