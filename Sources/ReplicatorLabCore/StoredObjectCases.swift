import Foundation

extension DDLCompatibilityCases {
    static let viewRenames = Case(
        "view-renames", "View and table rename chains retain definitions, journal, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10)"),
            .init("CREATE TABLE ddlcompat.aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n FROM ddlcompat.t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.v2 AS SELECT id,n+1 AS n FROM ddlcompat.t"
            ),
            .init(
                "RENAME TABLE ddlcompat.v TO ddlcompat.renamed",
                [
                    .init("SELECT * FROM ddlcompat.renamed", "1\t10"),
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='renamed'",
                        "root@localhost\tINVOKER\tLOCAL"),
                ], restartBefore: true),
            .init(
                "RENAME TABLE ddlcompat.renamed TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.renamed,ddlcompat.tmp TO ddlcompat.v2",
                [
                    .init("SELECT * FROM ddlcompat.renamed", "1\t11"), .init("SELECT * FROM ddlcompat.v2", "1\t10"),
                ]),
            .init(
                "RENAME TABLE ddlcompat.aux TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.aux,ddlcompat.tmp TO ddlcompat.v2",
                [
                    .init("SELECT * FROM ddlcompat.aux", "1\t10"), .init("SELECT * FROM ddlcompat.v2", "2\t20"),
                ], restartBefore: true),
            .init("UPDATE ddlcompat.v2 SET n=21 WHERE id=2", [.init("SELECT * FROM ddlcompat.v2", "2\t21")]),
            .init(
                "INSERT INTO ddlcompat.aux VALUES(3,30)",
                [.init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t10\n3\t30")]),
            .init(
                "RENAME TABLE ddlcompat.v2 TO ddlcompat.moved,ddlcompat.aux TO ddlcompat.final_view",
                [
                    .init("SELECT * FROM ddlcompat.final_view ORDER BY id", "1\t10\n3\t30"),
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='final_view'",
                        "root@localhost\tINVOKER\tLOCAL"),
                ]),
            .init(
                "DELETE FROM ddlcompat.moved WHERE id=2", [.init("SELECT COUNT(*) FROM ddlcompat.moved", "0")],
                restartBefore: true),
        ])
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
    static let storedObjects = Case(
        "stored-objects", "Routine ALTER, definers, view check options, multi-view DROP, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE ddlcompat.p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO ddlcompat.t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE ddlcompat.p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat' AND ROUTINE_NAME='p'",
                        "root@localhost\tINVOKER\tMODIFIES SQL DATA\tupdated procedure")
                ], restartBefore: true),
            .init(
                "ALTER FUNCTION ddlcompat.f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,IS_DETERMINISTIC,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat' AND ROUTINE_NAME='f'",
                        "root@localhost\tINVOKER\tREADS SQL DATA\tYES\tupdated function"),
                    .init("SELECT ddlcompat.f(7)", "8"),
                ]),
            .init("CALL ddlcompat.p(1)", [.init("SELECT * FROM ddlcompat.t", "1\t11")]),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v(id,n) AS (SELECT id,n FROM ddlcompat.t WHERE n>0) WITH LOCAL CHECK OPTION",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='v'",
                        "root@localhost\tINVOKER\tLOCAL\tYES")
                ]),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v2 AS (SELECT id,n FROM ddlcompat.t)"
            ),
            .init(
                "INSERT INTO ddlcompat.v VALUES(2,20)",
                [.init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t11\n2\t20")], restartBefore: true),
            .init(
                "ALTER ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.v AS (SELECT id,n FROM ddlcompat.t WHERE n>0) WITH CASCADED CHECK OPTION",
                [
                    .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='v'",
                        "root@localhost\tDEFINER\tCASCADED\tYES")
                ]),
            .init(
                "UPDATE ddlcompat.v SET n=21 WHERE id=2",
                [.init("SELECT * FROM ddlcompat.v2 ORDER BY id", "1\t11\n2\t21")]),
            .init(
                "DROP VIEW IF EXISTS ddlcompat.v,ddlcompat.v2,ddlcompat.absent CASCADE",
                [
                    .init("SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'", "0")
                ]),
            .init("DROP PROCEDURE IF EXISTS ddlcompat.p"),
            .init(
                "DROP FUNCTION IF EXISTS ddlcompat.f",
                [.init("SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'", "0")]),
            .init(
                "DELETE FROM ddlcompat.t WHERE id=1", [.init("SELECT * FROM ddlcompat.t", "2\t21")], restartBefore: true
            ),
        ])
}
