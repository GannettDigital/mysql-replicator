import Foundation

extension SharedCorrectness.Run {
    func basicDML() throws {
        guard selects(DDLCoverageCases.positive.id) else { return }
        try resetNativeEngine()
        try f.awaitNative()
        let isolated = LabIsolatedApply(f)
        for role in LabProfile.Role.allCases {
            _ = try f.sql(
                role,
                "SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS poc.items; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(f.profile.engine(role)); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)"
            )
        }
        try reporter.run(DDLCoverageCases.positive) {
            var starts: [LabProfile.Role: Boundary] = [:]
            for role in LabProfile.Role.allCases { starts[role] = try f.boundary(role) }
            var config = isolated.configuration("positive", at: starts[.source]!, count: 4)
            for (endpoint, password) in [("source", "fixture-capture-only"), ("target", "fixture-apply-only")] {
                var connection = config[endpoint] as! [String: Any]
                connection.removeValue(forKey: "passwordEnvironment")
                connection["password"] = password
                config[endpoint] = connection
            }
            let client = try isolated.start("positive", config: config)
            _ = try f.sql(.source, Fixture.sql(transaction: false))
            let end = try f.boundary()
            let result = try isolated.finish(client, label: "positive", config: config)
            try f.awaitNative()
            try require(
                result["transactionsApplied"] as? Int == 4 && result["rowsApplied"] as? Int == 4,
                "basic counters differ")
            for role in LabProfile.Role.allCases {
                try require(f.h.rows(f.profile.service(role)) == Fixture.final, "basic DML rows differ")
                try Comparison.operations(
                    f.h.capture(f.profile.service(role), start: starts[role]!, end: f.boundary(role)),
                    expected: Fixture.operations)
                let directory = f.output.appendingPathComponent(f.profile.service(role))
                try FileManager.default.copyItem(
                    at: directory.appendingPathComponent("operations.json"),
                    to: directory.appendingPathComponent("positive-operations.json"))
            }
            let sourceDelta = try f.sql(
                .source,
                "SELECT GTID_SUBTRACT('\(end.gtids)','\(starts[.source]!.gtids)')")
            let targetDelta = try f.sql(
                .target,
                "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'\(starts[.target]!.gtids)')")
            let preserves = (config["target"] as? [String: Any])?["preserveSourceGTIDs"] as? Bool ?? true
            if preserves {
                try require(
                    f.sql(
                        .target,
                        "SELECT GTID_SUBSET('\(sourceDelta)','\(targetDelta)') AND GTID_SUBSET('\(targetDelta)','\(sourceDelta)')"
                    ) == "1",
                    "target did not preserve exactly the applied source GTIDs")
            } else {
                try require(
                    f.sql(.target, "SELECT GTID_SUBTRACT('\(sourceDelta)','\(targetDelta)')") == sourceDelta,
                    "target retained source GTIDs with preservation disabled")
            }
            if !f.profile.transactionalTarget && f.dmlTransport == "sql" {
                let reads = (result["stageTimings"] as? [String: [String: Any]])?["target.read"]?["count"] as? Int
                try require(reads == 3, "basic DML repeated existence reads")
            }
            if f.dmlTransport == "binlog" {
                let writes =
                    (result["stageTimings"] as? [String: [String: Any]])?["target.binlog.rows"]?["count"] as? Int
                try require(writes == 4, "basic DML did not use four BINLOG row requests")
            }
            let saved = try isolated.state(
                "positive",
                "SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||applied_position||'|'||(SELECT gtids FROM snapshots ORDER BY id DESC LIMIT 1) FROM state"
            )
            try require(saved == "STOPPED|4|4|\(end.position)|\(end.gtids)", "basic durable boundary differs")
            try require(
                isolated.state("positive", "SELECT COUNT(*) FROM row_intents WHERE status='DONE'") == "4",
                "basic row intents missing")
            try require(
                isolated.state("positive", "SELECT target_uuid FROM state") == f.sql(.target, "SELECT @@server_uuid"),
                "target identity not persisted")
            try writeJSON(result, to: f.output.appendingPathComponent("positive-summary.json"))
        }
    }

}

extension SharedCorrectness.Run {
    /// Prove that this fixture emitted a diff, not only a complete JSON after image.
    func verifyJSONDiff(_ before: Boundary, label: String) throws {
        let end = try f.boundary()
        try require(before.file == end.file, "JSON diff fixture rotated within one phase")
        // The minimal 8.4 server image has no mysqlbinlog executable.
        // Use the same independent host decoder as the other binlog checks.
        let version = try f.runner.run([f.h.decoder, "--no-defaults", "--version"]).text
        try require(version.contains("Ver 8.4."), "Partial JSON checks require MySQL 8.4 mysqlbinlog; set MYSQLBINLOG")
        let container = try f.h.compose(["ps", "-q", f.profile.service(.source)]).text
        let file = f.output.appendingPathComponent(label + "-source.binlog")
        _ = try f.docker(["cp", container + ":/var/lib/mysql/" + before.file, file.path])
        let output = try f.runner.run([
            f.h.decoder, "--no-defaults", "--verify-binlog-checksum", "--base64-output=DECODE-ROWS", "-vv",
            "--start-position=\(before.position)", "--stop-position=\(end.position)", file.path,
        ]).stdout
        try output.write(to: f.output.appendingPathComponent(label + "-source-diff.txt"))
        let text = String(decoding: output, as: UTF8.self)
        try require(
            ["JSON_REPLACE(", "JSON_INSERT(", "JSON_REMOVE("].contains(where: text.contains),
            "source did not emit a partial JSON change")
    }
}
