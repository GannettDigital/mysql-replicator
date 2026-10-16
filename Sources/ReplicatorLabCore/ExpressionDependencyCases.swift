import Foundation

extension SharedCorrectness.Run {
    func expressionTarget84Dependencies() throws {
        guard f.profile == .reverse, selects("expression-target84-dependencies") else { return }
        try reporter.run(
            .init(
                "expression-target84-dependencies",
                "8.4 target expression dependencies, compound ALTER, refusal, restart and replay")
        ) {
            try resetNativeEngine()
            try f.awaitNative()
            let base =
                "SET sql_log_bin=0; DROP DATABASE IF EXISTS expression_ddl; CREATE DATABASE expression_ddl CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "
            let ordinary =
                "CREATE TABLE expression_ddl.t(id INT PRIMARY KEY,a INT,d INT,b INT,e INT,c INT,f INT,KEY by_a(a),KEY by_b(b),KEY by_c(c)) ENGINE=InnoDB"
            let enhanced =
                "CREATE TABLE expression_ddl.t(id INT PRIMARY KEY,a INT,d INT DEFAULT(a+1),b INT,e INT DEFAULT(b+2),c INT,f INT DEFAULT(c+3),KEY by_a ((a+1)),KEY by_b ((b+1)),KEY by_c ((c+1)),KEY retained ((id+1))) ENGINE=InnoDB"
            func seed() throws {
                for role in LabProfile.Role.allCases {
                    _ = try f.sql(role, base + (role == .target ? enhanced : ordinary))
                }
            }
            let isolated = LabIsolatedApply(f)
            let original = f.config
            defer { f.config = original }
            // 5.7 cannot create these expressions. Its ordinary indexes let the
            // same ALTER reach an 8.4 target with additional schema dependencies.
            for (label, reason) in [
                ("functional", "functional index by_a"), ("default", "unchanged default expression of column d"),
            ] {
                try seed()
                if label == "default" {
                    _ = try f.sql(.target, "SET sql_log_bin=0;ALTER TABLE expression_ddl.t DROP INDEX by_a")
                }
                let start = try f.boundary()
                let name = "expression-refuse-" + label
                let config = isolated.configuration(name, at: start, count: 1)
                _ = try f.sql(.source, session + "ALTER TABLE expression_ddl.t CHANGE a aa INT")
                try f.awaitNative()
                let client = try isolated.start(name, config: config)
                _ = try isolated.finish(client, label: name, config: config, reason: reason)
                try require(
                    isolated.state(name, "SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0",
                    "expression dependency refusal advanced progress")
                try require(
                    f.sql(
                        .target,
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='expression_ddl' AND TABLE_NAME='t' AND COLUMN_NAME='a'"
                    ) == "1", "expression dependency refusal changed the target")
            }
            try seed()
            let start = try f.boundary()
            let config = isolated.configuration("expression-live", at: start, count: 1)
            let statements = [
                "INSERT INTO expression_ddl.t VALUES(1,5,6,7,9,10,13),(2,20,21,22,24,25,28)",
                "ALTER TABLE expression_ddl.t CHANGE a aa INT,DROP INDEX by_a,ALTER d DROP DEFAULT,ADD INDEX by_a(aa)",
                "ALTER TABLE expression_ddl.t DROP INDEX by_b,ALTER e SET DEFAULT 9,CHANGE b bb INT",
                "ALTER TABLE expression_ddl.t DROP c,DROP f,DROP INDEX by_c",
                "UPDATE expression_ddl.t SET aa=aa+1,d=d+1,bb=bb+1,e=e+1 WHERE id=1",
                "INSERT INTO expression_ddl.t(id,aa,d,bb) VALUES(3,30,31,32)",
                "DELETE FROM expression_ddl.t WHERE id=2",
            ]
            func verify(_ label: String, stage: Int) throws {
                try f.awaitNative()
                let sql = "SELECT * FROM expression_ddl.t ORDER BY id"
                let expected = try f.sql(.source, sql)
                let native = try f.sql(.native, sql)
                let target = try f.sql(.target, sql)
                try Data("source\n\(expected)\nnative\n\(native)\ntarget\n\(target)\n".utf8).write(
                    to: f.output.appendingPathComponent(label + "-rows.txt"))
                try require(
                    native == expected && target == expected,
                    "expression dependency rows differ; inspect " + label + "-rows.txt")
                let functional = try f.sql(
                    .target,
                    "SELECT INDEX_NAME,EXPRESSION FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='expression_ddl' AND TABLE_NAME='t' AND EXPRESSION IS NOT NULL ORDER BY INDEX_NAME"
                )
                try Data(functional.utf8).write(to: f.output.appendingPathComponent(label + "-indexes.tsv"))
                try require(
                    functional.split(separator: "\n").count == 4 - min(stage, 3), "functional index count differs")
                try require(
                    f.sql(
                        .target,
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='expression_ddl' AND TABLE_NAME='t' AND EXTRA='DEFAULT_GENERATED'"
                    ) == String(3 - min(stage, 3)), "expression default count differs")
                try require(
                    f.sql(.target, "SELECT id FROM expression_ddl.t FORCE INDEX(retained) WHERE id+1=2") == "1",
                    "retained functional index query differs")
            }
            var completed: [String: Any] = [:]
            for (i, sql) in statements.enumerated() {
                let label = "expression-live-\(i)"
                _ = try f.sql(.source, session + sql)
                let client = try isolated.start(label, config: config, initialize: i == 0)
                completed = try isolated.finish(client, label: label, config: config)
                try verify(label, stage: i)
            }
            let end = try f.boundary()
            try require(
                completed["appliedGTIDSet"] as? String == end.gtids, "expression dependency live checkpoint differs")
            f.config = config
            var source = config["source"] as! [String: Any]
            source.removeValue(forKey: "stopAfterTransactions")
            f.config["source"] = source
            f.config["archive"] = ["directory": "/evidence/expression-archive", "firstFile": start.file]
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
                    exit == "0", "expression dependency command failed; inspect " + label + ".ndjson and support bundle"
                )
                let bytes = command == "replay" ? logs.stderr : logs.stdout
                guard let line = bytes.split(separator: 10).last,
                    let result = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { throw LabError("missing expression dependency summary") }
                return result
            }
            _ = try invoke("expression-fetch", "fetch")
            _ = try f.sql(.target, base + enhanced)
            f.config["stateDirectory"] = "/evidence/expression-replay"
            source["host"] = "127.0.0.1"
            source["port"] = 1
            source.removeValue(forKey: "passwordEnvironment")
            source.removeValue(forKey: "password")
            source["stopAfterTransactions"] = 2
            f.config["source"] = source
            _ = try invoke("expression-replay-first", "replay", initialize: true)
            source.removeValue(forKey: "stopAfterTransactions")
            f.config["source"] = source
            let replay = try invoke("expression-replay-resume", "replay")
            try require(
                replay["appliedGTIDSet"] as? String == end.gtids
                    && replay["transactionsApplied"] as? Int == statements.count,
                "expression dependency replay checkpoint differs")
            try verify("expression-replay", stage: 3)
            try require(
                f.sql(.target, "SELECT aa,d,bb,e FROM expression_ddl.t WHERE id=3") == "30\t31\t32\t9",
                "replacement default value differs")
        }
    }
}
