import Foundation

extension DDLCompatibilityCases {
    static let conditionalRoutines = Case(
        "conditional-routines",
        "Conditional routine creation preserves existing bodies, records no-ops and supports replay",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO ddlcompat.t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO ddlcompat.t VALUES(k,k+999)",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat' AND ROUTINE_NAME='p'",
                        "root@localhost\tDEFINER\toriginal")
                ], restartBefore: true),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999",
                [
                    .init("SELECT ddlcompat.f(7)", "8"),
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat' AND ROUTINE_NAME='f'",
                        "root@localhost\tDEFINER"),
                ]),
            .init("CALL ddlcompat.p(1)", [.init("SELECT * FROM ddlcompat.t", "1\t11")]),
            .init("DROP PROCEDURE ddlcompat.p"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY INVOKER INSERT INTO ddlcompat.t VALUES(k,k+20)",
                restartBefore: true),
            .init("CALL ddlcompat.p(2)", [.init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t11\n2\t22")]),
            .init(
                "INSERT INTO ddlcompat.t VALUES(3,ddlcompat.f(7))",
                [.init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t11\n2\t22\n3\t8")]),
        ],
        profileExclusions: [
            .reverse: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
            .mysql57MyISAM: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
            .mysql57InnoDB: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
        ])
}
