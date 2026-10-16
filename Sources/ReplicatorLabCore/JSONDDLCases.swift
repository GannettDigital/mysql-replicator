import Foundation

extension DDLCompatibilityCases {
    static let jsonGeneratedIndexes = Case(
        "json-indexes", "JSON generated-column indexes, ALTER, CREATE LIKE, row changes and restart",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,doc JSON,name VARCHAR(40) AS (doc->>'$.name') STORED,KEY by_name(name)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,doc JSON,name VARCHAR(40) AS (doc->>'$.name') VIRTUAL,KEY by_name(name)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.t(id,doc) VALUES(1,JSON_OBJECT('name','alpha','n',10)),(2,JSON_OBJECT('name','beta','n',20)),(3,NULL)",
                [
                    .init("SELECT id,name FROM ddlcompat.t FORCE INDEX(by_name) WHERE name='beta'", "2\tbeta")
                ]),
            .init(
                "UPDATE ddlcompat.t SET doc=JSON_OBJECT('name','gamma','n',30) WHERE id=1",
                [
                    .init("SELECT id,name FROM ddlcompat.t FORCE INDEX(by_name) WHERE name='gamma'", "1\tgamma")
                ], restartBefore: true),
            .init("ALTER TABLE ddlcompat.t ADD n INT AS (JSON_EXTRACT(doc,'$.n')) STORED, ADD INDEX by_n(n)"),
            .init(
                "INSERT INTO ddlcompat.t(id,doc) VALUES(4,JSON_OBJECT('name','delta','n',40))",
                [
                    .init("SELECT id,n FROM ddlcompat.t FORCE INDEX(by_n) WHERE n=40", "4\t40")
                ]),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init(
                "INSERT INTO ddlcompat.copy(id,doc) SELECT id,doc FROM ddlcompat.t",
                [
                    .init(
                        "SELECT id,name,n FROM ddlcompat.copy ORDER BY id", "1\tgamma\t30\n3\tNULL\tNULL\n4\tdelta\t40")
                ]),
            .init("ALTER TABLE ddlcompat.copy DROP INDEX by_name, ADD INDEX renamed_name(name)", restartBefore: true),
            .init(
                "UPDATE ddlcompat.copy SET doc=JSON_OBJECT('name','final','n',50) WHERE id=4",
                [
                    .init(
                        "SELECT id,name,n FROM ddlcompat.copy FORCE INDEX(renamed_name) WHERE name='final'",
                        "4\tfinal\t50")
                ]),
        ])
}

extension SharedCorrectness.Run {
    func jsonTarget57Limits() throws {
        guard f.profile == .forward, selects("json-target57-limits") else { return }
        try reporter.run(
            .init("json-target57-limits", "Native 5.7 version and MyISAM engine limits stop JSON DDL before target SQL")
        ) {
            try setNativeEngine("InnoDB")
            try f.awaitNative()
            let seed =
                "SET sql_log_bin=0; DROP DATABASE IF EXISTS json_limits; CREATE DATABASE json_limits CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, seed) }
            let isolated = LabIsolatedApply(f)
            let cases = [
                ("defaults", "doc JSON DEFAULT (JSON_OBJECT())", "MySQL 5.7 does not support expression defaults"),
                (
                    "functional", "doc JSON,KEY by_n ((CAST(doc->'$.n' AS UNSIGNED)))",
                    "MySQL 5.7 does not support functional indexes"
                ),
                (
                    "virtual", "doc JSON,n INT AS (doc->'$.n') VIRTUAL,KEY by_n(n)",
                    "MyISAM does not support indexes on VIRTUAL generated columns"
                ),
            ]
            for (name, columns, reason) in cases {
                let label = "json-limit-" + name
                let start = try f.boundary()
                let config = isolated.configuration(label, at: start, count: 1)
                _ = try f.sql(
                    .source, session + "CREATE TABLE json_limits." + name + "(id INT PRIMARY KEY," + columns + ")")
                try f.awaitNative()
                let client = try isolated.start(label, config: config)
                _ = try isolated.finish(client, label: label, config: config, reason: reason)
                try require(
                    f.sql(.target, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='json_limits'")
                        == "0", "refused JSON DDL created a target table")
                try require(
                    isolated.state(label, "SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0",
                    "refused JSON DDL advanced progress")
            }
            try resetNativeEngine()
        }
    }
    func jsonTarget84Schema() throws {
        guard f.profile == .reverse, selects("json-target84-schema") else { return }
        try reporter.run(
            .init(
                "json-target84-schema",
                "Existing 8.4 JSON defaults and functional indexes survive DML, restart and replay")
        ) {
            try resetNativeEngine()
            try f.awaitNative()
            let base =
                "SET sql_log_bin=0; DROP DATABASE IF EXISTS json_ddl; CREATE DATABASE json_ddl CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "
            let ordinary = "CREATE TABLE json_ddl.t(id INT PRIMARY KEY,doc JSON) ENGINE=InnoDB"
            let enhanced =
                "CREATE TABLE json_ddl.t(id INT PRIMARY KEY,doc JSON DEFAULT (JSON_OBJECT('name','default')), KEY by_name ((CAST(doc->>'$.name' AS CHAR(40)) COLLATE utf8mb4_bin)), KEY by_n ((CAST(doc->'$.n' AS UNSIGNED)))) ENGINE=InnoDB"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, base + (role == .target ? enhanced : ordinary)) }
            let start = try f.boundary()
            let isolated = LabIsolatedApply(f)
            let original = f.config
            defer { f.config = original }
            let config = isolated.configuration("json-ddl-live", at: start, count: 1)
            func apply(_ label: String, initialize: Bool = false) throws -> [String: Any] {
                let client = try isolated.start(label, config: config, initialize: initialize)
                return try isolated.finish(client, label: label, config: config)
            }
            func verify() throws {
                try f.awaitNative()
                let sql =
                    "SELECT id,JSON_UNQUOTE(JSON_EXTRACT(doc,'$.name')),JSON_EXTRACT(doc,'$.n') FROM json_ddl.t ORDER BY id"
                let expected = try f.sql(.source, sql)
                try require(
                    f.sql(.native, sql) == expected && f.sql(.target, sql) == expected,
                    "JSON expression target rows differ from source/native")
                try require(
                    f.sql(
                        .target,
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='json_ddl' AND TABLE_NAME='t' AND EXPRESSION IS NOT NULL"
                    ) == "2", "functional index metadata was lost")
                try require(
                    f.sql(
                        .target,
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='json_ddl' AND TABLE_NAME='t' AND EXTRA='DEFAULT_GENERATED'"
                    ) == "1", "JSON expression default was lost")
            }
            _ = try f.sql(
                .source, session + "INSERT INTO json_ddl.t VALUES(1,JSON_OBJECT('name','alpha','n',10)),(2,NULL)")
            _ = try apply("json-ddl-insert", initialize: true)
            try verify()
            _ = try f.sql(.source, session + "UPDATE json_ddl.t SET doc=JSON_OBJECT('name','beta','n',20) WHERE id=1")
            _ = try apply("json-ddl-update")
            try verify()
            try require(
                f.sql(
                    .target,
                    "SELECT id FROM json_ddl.t FORCE INDEX(by_name) WHERE (CAST(doc->>'$.name' AS CHAR(40)) COLLATE utf8mb4_bin)='beta'"
                ) == "1", "functional index lookup differs")
            _ = try f.sql(.source, session + "DELETE FROM json_ddl.t WHERE id=2")
            let completed = try apply("json-ddl-delete")
            try verify()
            let end = try f.boundary()
            try require(completed["appliedGTIDSet"] as? String == end.gtids, "JSON expression live checkpoint differs")
            // Reset only the target. Replay must discover the same target-only
            // metadata and retain it across a saved-state restart.
            f.config = config
            var source = config["source"] as! [String: Any]
            source.removeValue(forKey: "stopAfterTransactions")
            f.config["source"] = source
            f.config["archive"] = ["directory": "/evidence/json-ddl-archive", "firstFile": start.file]
            func invoke(_ label: String, _ command: String, initialize: Bool = false) throws -> [String: Any] {
                try f.installConfig(label)
                let client = try f.startClient(
                    label,
                    arguments: [command, "--config", "/evidence/" + label + ".yaml"]
                        + (initialize ? ["--initialize"] : []))
                let exit = try f.runner.run(["docker", "wait", client], timeout: 120).text
                let logs = try f.docker(["logs", client])
                try (logs.stdout + logs.stderr).write(to: f.output.appendingPathComponent(label + ".ndjson"))
                try require(
                    exit == "0", "JSON expression command failed; inspect " + label + ".ndjson and support bundle")
                let bytes = command == "replay" ? logs.stderr : logs.stdout
                guard let line = bytes.split(separator: 10).last,
                    let result = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { throw LabError("missing JSON expression summary") }
                return result
            }
            _ = try invoke("json-ddl-fetch", "fetch")
            _ = try f.sql(.target, base + enhanced)
            f.config["stateDirectory"] = "/evidence/json-ddl-replay"
            source["host"] = "127.0.0.1"
            source["port"] = 1
            source.removeValue(forKey: "passwordEnvironment")
            source.removeValue(forKey: "password")
            source["stopAfterTransactions"] = 1
            f.config["source"] = source
            _ = try invoke("json-ddl-replay-insert", "replay", initialize: true)
            source.removeValue(forKey: "stopAfterTransactions")
            f.config["source"] = source
            let replay = try invoke("json-ddl-replay-resume", "replay")
            try require(
                replay["appliedGTIDSet"] as? String == end.gtids && replay["transactionsApplied"] as? Int == 3,
                "JSON expression replay checkpoint differs")
            try verify()
            _ = try f.sql(.target, "INSERT INTO json_ddl.t(id) VALUES(99)")
            try require(
                f.sql(.target, "SELECT doc->>'$.name' FROM json_ddl.t WHERE id=99") == "default",
                "JSON expression default did not execute")
        }
    }
}
