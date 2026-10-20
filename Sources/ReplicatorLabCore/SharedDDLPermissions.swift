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
            // No writes occurred. Keep the blocked state and start from the same
            // baseline in a fresh state. Rejected DDL has no retry resolver yet.
            _ = try f.sql(.target, "SET GLOBAL explicit_defaults_for_timestamp=1")
            config["stateDirectory"] = "/evidence/ddl-permissions-enabled"
            let resumed = try isolated.start("ddl-permissions-enabled", config: config)
            _ = try isolated.finish(resumed, label: "ddl-permissions-enabled", config: config)
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
        }
    }
}
