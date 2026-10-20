import Foundation

extension DDLCompatibilityCases {
    static let absentDefiners = Case(
        "absent-definers", "Absent definers retain native metadata, invoker behavior and execution errors",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10)"),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.invoker_view AS SELECT id,n FROM ddlcompat.t",
                [.init("SELECT * FROM ddlcompat.invoker_view", "1\t10")]),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.definer_view AS SELECT id,n FROM ddlcompat.t",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='definer_view'",
                        "beta6_absent@localhost\tDEFINER")
                ], restartBefore: true),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' FUNCTION ddlcompat.f() RETURNS INT DETERMINISTIC SQL SECURITY INVOKER RETURN 7",
                [.init("SELECT ddlcompat.f()", "7")]),
            .init("ALTER FUNCTION ddlcompat.f SQL SECURITY DEFINER", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=20 WHERE id=1", [.init("SELECT * FROM ddlcompat.invoker_view", "1\t20")]),
        ])
}

extension SharedCorrectness.Run {
    func verifyAbsentDefinerErrors() throws {
        for role in LabProfile.Role.allCases {
            for (name, sql) in [("view", "SELECT * FROM ddlcompat.definer_view"), ("routine", "SELECT ddlcompat.f()")] {
                let before = try f.boundary(role)
                let result = try f.h.compose(
                    [
                        "exec", "-T", "-e", "MYSQL_PWD=fixture-root-only", f.profile.service(role), "mysql",
                        "--no-defaults", "-uroot", "-e", sql,
                    ], checked: false)
                let message = String(decoding: result.stderr, as: UTF8.self)
                try require(
                    result.status != 0 && message.contains("ERROR 1449 "), "absent definer result differs: " + message)
                try (result.stdout + result.stderr).write(
                    to: f.output.appendingPathComponent(
                        "absent-definer-" + f.profile.service(role) + "-" + name + ".txt"))
                let after = try f.boundary(role)
                try require(
                    before.file == after.file && before.position == after.position && before.gtids == after.gtids,
                    "failed definer execution changed the binlog")
            }
        }
    }
}
