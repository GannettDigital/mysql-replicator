import Foundation

extension SharedCorrectness.Run {
    func ddlSessionPermissions() throws {
        guard f.profile == .mysql57InnoDB, selects("ddl-session-permissions") else { return }
        try reporter.run(.init("ddl-session-permissions", "DDL without SUPER, restart and session failure diagnostics"))
        {
            try f.awaitNative()
            let initialDefault = try f.sql(.target, "SELECT @@GLOBAL.explicit_defaults_for_timestamp")
            defer {
                _ = try? f.sql(.target, "SET GLOBAL explicit_defaults_for_timestamp=\(initialDefault)")
                _ = try? f.sql(.target, "SET sql_log_bin=0; DROP USER IF EXISTS 'ddl_no_super'@'%'")
            }
            _ = try f.sql(
                .target,
                "SET sql_log_bin=0; CREATE USER 'ddl_no_super'@'%' IDENTIFIED BY 'fixture-ddl-only'; "
                    + "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,RELOAD,SHUTDOWN,PROCESS,REFERENCES,INDEX,ALTER,SHOW DATABASES,CREATE TEMPORARY TABLES,LOCK TABLES,EXECUTE,REPLICATION SLAVE,REPLICATION CLIENT,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,CREATE USER,EVENT,TRIGGER,CREATE TABLESPACE ON *.* TO 'ddl_no_super'@'%'"
            )
            try require(
                f.sql(.target, "SELECT Super_priv FROM mysql.user WHERE User='ddl_no_super' AND Host='%'") == "N",
                "test account has SUPER")
            let seed =
                "SET sql_log_bin=0; CREATE DATABASE ddl_permissions CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; "
                + "CREATE TABLE ddl_permissions.original(id INT PRIMARY KEY,ts TIMESTAMP NULL DEFAULT NULL) ENGINE=InnoDB"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, seed) }
            let start = try f.boundary()
            _ = try f.sql(
                .source,
                session + "CREATE TABLE ddl_permissions.copied LIKE ddl_permissions.original; "
                    + "INSERT INTO ddl_permissions.copied VALUES(1,'2026-01-02 03:04:05')")
            try f.awaitNative()
            let isolated = LabIsolatedApply(f)
            var config = isolated.configuration("ddl-permissions", at: start, count: 2)
            var target = config["target"] as! [String: Any]
            target["username"] = "ddl_no_super"
            target.removeValue(forKey: "passwordEnvironment")
            target["password"] = "fixture-ddl-only"
            target["preserveSourceGTIDs"] = false
            target["transport"] = "sql"
            config["target"] = target
            // OFF needs a privileged SET. Refuse before the source DDL is issued.
            _ = try f.sql(.target, "SET GLOBAL explicit_defaults_for_timestamp=0")
            let denied = try isolated.start("ddl-permissions-denied", config: config)
            let failure = try isolated.finish(
                denied, label: "ddl-permissions-denied", config: config,
                reason: "DDL requires explicit_defaults_for_timestamp=ON")
            let progress = failure["progress"] as? [String: Any]
            let diagnostic = progress?["targetFailure"] as? [String: Any]
            let operation = diagnostic?["targetSQL"] as? [String: Any]
            let statement = diagnostic?["statement"] as? [String: Any]
            try require(operation?["mysqlErrorNumber"] as? Int == 1227, "missing MySQL error number")
            try require(operation?["sqlState"] as? String == "42000", "missing SQLSTATE")
            try require(
                operation?["sql"] as? String == "SET SESSION explicit_defaults_for_timestamp=1", "wrong failed SQL")
            try require((operation?["serverMessage"] as? String ?? "").contains("SUPER"), "missing privilege name")
            try require(statement?["phase"] as? String == "notIssued", "DDL was issued after failed session setup")
            try require(
                isolated.state("ddl-permissions-denied", "SELECT COUNT(*) FROM ddl_intents") == "0",
                "unexpected DDL intent")
            try require(
                f.sql(
                    .target,
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddl_permissions' AND TABLE_NAME='copied'"
                ) == "0", "failed session setup created a table")
            func resolveRetry(_ label: String, failure: [String: Any]) throws {
                guard let progress = failure["progress"] as? [String: Any],
                    let pending = progress["pendingGTID"] as? String,
                    let baseline = progress["appliedGTIDSet"] as? String
                else { throw LabError("missing rejected DDL progress") }
                func recover(_ arguments: [String]) throws -> [String: Any] {
                    let result = try f.docker(
                        [
                            "run", "--rm", "--platform", "linux/amd64", "--network", "none", "--mount",
                            "type=volume,src=\(f.volume),dst=/evidence", "--entrypoint",
                            "/usr/local/bin/mysql-replicator", f.image,
                            "recovery",
                        ] + arguments + ["--config", "/evidence/" + label + ".yaml"])
                    try result.stdout.write(to: f.output.appendingPathComponent(label + "-" + arguments[0] + ".json"))
                    return try JSONSerialization.jsonObject(with: result.stdout) as! [String: Any]
                }
                let inspected = try recover(["inspect"])
                let pendingGroups = inspected["pending"] as? [[String: Any]]
                try require(
                    pendingGroups?.count == 1 && pendingGroups?[0]["rejectedDDL"] != nil,
                    "inspection did not report rejected DDL")
                let resolved = try recover([
                    "resolve", "retry", "--gtids", pending, "--reason",
                    "fixture confirmed no DDL intent or target write; DBA enabled the timestamp default",
                ])
                try require(
                    resolved["lifecycle"] as? String == "STOPPED"
                        && resolved["resumeGTIDSet"] as? String == baseline, "DDL retry advanced the checkpoint")
            }
            _ = try f.sql(.target, "SET GLOBAL explicit_defaults_for_timestamp=1")
            try resolveRetry("ddl-permissions-denied", failure: failure)
            let resumed = try isolated.start("ddl-permissions-enabled", config: config, initialize: false)
            _ = try isolated.finish(resumed, label: "ddl-permissions-enabled", config: config)
            try require(
                isolated.state("ddl-permissions-enabled", "SELECT action FROM recovery_audit") == "retry",
                "missing persisted DDL retry audit")
            let rows = "SELECT id,ts FROM ddl_permissions.copied ORDER BY id"
            try require(f.sql(.target, rows) == f.sql(.native, rows), "restricted DDL/DML differ from native")
            _ = try f.sql(.source, session + "ALTER TABLE ddl_permissions.copied ADD COLUMN n INT DEFAULT 7")
            var source = config["source"] as! [String: Any]
            source["stopAfterTransactions"] = 1
            config["source"] = source
            let restarted = try isolated.start("ddl-permissions-restarted", config: config, initialize: false)
            let completed = try isolated.finish(restarted, label: "ddl-permissions-restarted", config: config)
            try f.awaitNative()
            try require(completed["transactionsApplied"] as? Int == 3, "restart checkpoint differs")
            let updated = "SELECT id,ts,n FROM ddl_permissions.copied ORDER BY id"
            try require(
                f.sql(.target, updated) == f.sql(.native, updated), "restarted restricted DDL differs from native")
            // Repeat the rejected DDL and retry through replay. The source
            // address is unreachable during replay and recovery runs offline.
            var replayConfig = isolated.configuration("ddl-permissions-replay", at: start, count: 3)
            replayConfig["target"] = target
            replayConfig["archive"] = ["directory": "/evidence/ddl-permissions-archive", "firstFile": start.file]
            func startCommand(_ label: String, _ command: String, initialize: Bool) throws -> String {
                let original = f.config
                defer { f.config = original }
                f.config = replayConfig
                try f.installConfig(label)
                return try f.startClient(
                    label,
                    arguments: [command, "--config", "/evidence/" + label + ".yaml"]
                        + (initialize ? ["--initialize"] : []))
            }
            let fetch = try startCommand("ddl-permissions-fetch", "fetch", initialize: false)
            let fetchExit = try f.runner.run(["docker", "wait", fetch], timeout: 90).text
            let fetchLogs = try f.docker(["logs", fetch])
            try (fetchLogs.stdout + fetchLogs.stderr).write(
                to: f.output.appendingPathComponent("ddl-permissions-fetch.ndjson"))
            try require(fetchExit == "0", "DDL permissions archive fetch failed")
            _ = try f.sql(
                .target,
                "SET sql_log_bin=0; DROP TABLE ddl_permissions.copied; SET GLOBAL explicit_defaults_for_timestamp=0")
            var offlineSource = replayConfig["source"] as! [String: Any]
            offlineSource["host"] = "127.0.0.1"
            offlineSource["port"] = 1
            offlineSource.removeValue(forKey: "passwordEnvironment")
            offlineSource.removeValue(forKey: "password")
            replayConfig["source"] = offlineSource
            let replayDenied = try startCommand("ddl-permissions-replay-denied", "replay", initialize: true)
            let replayFailure = try isolated.finish(
                replayDenied, label: "ddl-permissions-replay-denied", config: replayConfig,
                reason: "DDL requires explicit_defaults_for_timestamp=ON")
            _ = try f.sql(.target, "SET GLOBAL explicit_defaults_for_timestamp=1")
            try resolveRetry("ddl-permissions-replay-denied", failure: replayFailure)
            let replay = try startCommand("ddl-permissions-replay-resumed", "replay", initialize: false)
            let replayed = try isolated.finish(replay, label: "ddl-permissions-replay-resumed", config: replayConfig)
            try require(replayed["transactionsApplied"] as? Int == 3, "replayed DDL checkpoint differs")
            try require(f.sql(.target, updated) == f.sql(.native, updated), "replayed DDL/data differ from native")

        }
    }
}
