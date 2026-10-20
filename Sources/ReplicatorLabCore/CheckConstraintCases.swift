import Foundation

extension DDLCompatibilityCases {
    static let ignoredChecks = Case(
        "ignored-checks",
        "Native 5.7 CHECK clauses create no target constraint; compound DDL, violating rows and restart",
        [
            .init(
                "CREATE TABLE ddlcompat.t(CONSTRAINT first_check CHECK(id>0), id INT PRIMARY KEY, v INT CHECK(v>0), CHECK(id<0), CONSTRAINT last_check CHECK(v<0))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(-1,-1),(1,1)"),
            .init("ALTER TABLE ddlcompat.t ADD CONSTRAINT never_check CHECK(v>100), ADD CHECK(v<0)"),
            .init("INSERT INTO ddlcompat.t VALUES(-2,-2)", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t ADD CHECK(v>0), ADD note INT DEFAULT 7 CHECK(note<0), ADD CHECK(note>100)"),
            .init("INSERT INTO ddlcompat.t(id,v) VALUES(-3,-3)"),
            .init("ALTER TABLE ddlcompat.t MODIFY v INT, ADD CHECK(v>100)"),
            .init("UPDATE ddlcompat.t SET v=-999 WHERE id=1", restartBefore: true),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t"),
            .init("ALTER TABLE ddlcompat.copy DROP COLUMN note"),
            .init(
                "DELETE FROM ddlcompat.t WHERE id=-1",
                [
                    .init("SELECT id,v,note FROM ddlcompat.t ORDER BY id", "-3\t-3\t7\n-2\t-2\t7\n1\t-999\t7"),
                    .init(
                        "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA='ddlcompat' AND CONSTRAINT_TYPE='CHECK'",
                        "0"),
                ]),
        ], profileExclusions: [.forward: "8.4 enforces CHECK constraints; 5.7 targets cannot preserve that behavior."])
}

extension SharedCorrectness.Run {
    func checkTarget57Limits() throws {
        guard f.profile == .forward, selects("check-target57-limits") else { return }
        try reporter.run(.init("check-target57-limits", "Reject enforced 8.4 CHECK constraints before target DDL")) {
            try setNativeEngine("InnoDB")
            try f.awaitNative()
            let seed =
                "SET sql_log_bin=0; DROP DATABASE IF EXISTS check_limits; CREATE DATABASE check_limits CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, seed) }
            let isolated = LabIsolatedApply(f)
            let start = try f.boundary()
            let label = "check-target-limit"
            let config = isolated.configuration(label, at: start, count: 1)
            _ = try f.sql(
                .source,
                session + "CREATE TABLE check_limits.t(id INT PRIMARY KEY,v INT,CONSTRAINT positive CHECK(v>0))")
            try f.awaitNative()
            let client = try isolated.start(label, config: config)
            _ = try isolated.finish(client, label: label, config: config, reason: "cannot preserve CHECK constraints")
            try require(
                f.sql(
                    .target,
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='check_limits' AND TABLE_NAME='t'"
                ) == "0", "unsupported CHECK reached the target")
        }
    }
}
