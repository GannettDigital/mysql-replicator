import Foundation

extension DDLCompatibilityCases {
    static let absentDefiners = Case(
        "absent-definers", "Stored object access control: absent DEFINER and SQL SECURITY INVOKER/DEFINER",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10)"),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.invoker_view AS SELECT id,n FROM ddlcompat.t",
                phaseEnd: "create-invoker-view"),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.definer_view AS SELECT id,n FROM ddlcompat.t",
                restartBefore: true),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' FUNCTION ddlcompat.f() RETURNS INT DETERMINISTIC SQL SECURITY INVOKER RETURN 7",
                phaseEnd: "create-definer-view-and-invoker-function"),
            .init("ALTER FUNCTION ddlcompat.f SQL SECURITY DEFINER", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=20 WHERE id=1"),
            .init("CREATE DATABASE absent_definer_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE absent_definer_results.ad_invoker_base(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO absent_definer_results.ad_invoker_base VALUES(1,10)"),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY INVOKER VIEW absent_definer_results.ad_invoker_view AS SELECT id,n FROM absent_definer_results.ad_invoker_base"
            ),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' SQL SECURITY DEFINER VIEW absent_definer_results.ad_definer_view AS SELECT id,n FROM absent_definer_results.ad_invoker_base"
            ),
            .init(
                "CREATE DEFINER='beta6_absent'@'localhost' FUNCTION absent_definer_results.ad_invoker_f() RETURNS INT DETERMINISTIC SQL SECURITY INVOKER RETURN 7",
                phaseEnd: "alter-security-update-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-invoker-view-rows",
                    check: .init("SELECT * FROM absent_definer_results.ad_invoker_view", "1\t10")),
                .init(
                    id: "original-definer-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='definer_view'",
                        "beta6_absent@localhost\tDEFINER")),
                .init(id: "invoker-function-result", check: .init("SELECT absent_definer_results.ad_invoker_f()", "7")),
                .init(id: "updated-invoker-view-rows", check: .init("SELECT * FROM ddlcompat.invoker_view", "1\t20")),
                .init(
                    id: "retained-invoker-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='absent_definer_results' AND TABLE_NAME='ad_invoker_view'",
                        "beta6_absent@localhost\tINVOKER")),
                .init(
                    id: "retained-invoker-function-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='absent_definer_results' AND ROUTINE_NAME='ad_invoker_f'",
                        "beta6_absent@localhost\tINVOKER")),
                .init(
                    id: "altered-function-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat' AND ROUTINE_NAME='f'",
                        "beta6_absent@localhost\tDEFINER")),
                .init(
                    id: "retained-definer-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='absent_definer_results' AND TABLE_NAME='ad_definer_view'",
                        "beta6_absent@localhost\tDEFINER")),
            ], databases: ["ddlcompat", "absent_definer_results"],
            cleanup: ["DROP DATABASE absent_definer_results"]
        ))
}

/// Each expected failure owns its boundary checks and stage-specific evidence.
struct AbsentDefinerErrorCheck {
    enum Stage: String, CaseIterable {
        case beforeReplay = "before-replay"
        case afterReplay = "after-replay"
    }
    let stage: Stage
    let role: LabProfile.Role
    let name: String
    let sql: String

    var id: String { "absent-definer-" + stage.rawValue + "-" + role.rawValue + "-" + name }
    var outputFile: String { id + ".txt" }

    static func checks(stage: Stage) -> [Self] {
        LabProfile.Role.allCases.flatMap { role in
            [("view", "SELECT * FROM ddlcompat.definer_view"), ("routine", "SELECT ddlcompat.f()")].map { name, sql in
                Self(stage: stage, role: role, name: name, sql: sql)
            }
        }
    }

    func observation(_ result: CommandResult, before: Boundary, after: Boundary) throws -> [String: Any] {
        let message = String(decoding: result.stderr, as: UTF8.self)
        try require(
            result.status != 0 && message.contains("ERROR 1449 "),
            "absent definer result differs; inspect " + outputFile + ": " + message)
        try require(
            before.file == after.file && before.position == after.position && before.gtids == after.gtids,
            "failed definer execution changed the binlog; inspect " + outputFile)
        return [
            "stage": stage.rawValue, "role": role.rawValue, "object": name, "sql": sql,
            "exitStatus": Int(result.status), "stderr": message,
            "stdout": String(decoding: result.stdout, as: UTF8.self), "outputFile": outputFile,
            "before": before.json, "after": after.json,
        ]
    }
}

extension SharedCorrectness.Run {
    func verifyAbsentDefinerErrors(_ stage: AbsentDefinerErrorCheck.Stage, caseID: String) throws {
        for check in AbsentDefinerErrorCheck.checks(stage: stage) {
            try assertion(check.id, caseID: caseID) {
                let before = try f.boundary(check.role)
                let result = try f.h.compose(
                    [
                        "exec", "-T", "-e", "MYSQL_PWD=fixture-root-only", f.profile.service(check.role), "mysql",
                        "--no-defaults", "-uroot", "-e", check.sql,
                    ], checked: false)
                try (result.stdout + result.stderr).write(to: f.output.appendingPathComponent(check.outputFile))
                let after = try f.boundary(check.role)
                return try check.observation(result, before: before, after: after)
            }
        }
    }
}
