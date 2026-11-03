import Foundation

extension DDLCompatibilityCases {
    static let storedObjects = Case(
        "stored-objects", "Stored routines and views: ALTER characteristics, CHECK OPTION and row effects",
        [
            // Original statements keep their order and restart points. Retained objects use a separate database.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE ddlcompat.p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO ddlcompat.t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1",
                phaseEnd: "create-routines"),
            .init(
                "ALTER PROCEDURE ddlcompat.p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'",
                restartBefore: true),
            .init("ALTER FUNCTION ddlcompat.f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"),
            .init("CALL ddlcompat.p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v(id,n) AS (SELECT id,n FROM ddlcompat.t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v2 AS (SELECT id,n FROM ddlcompat.t)",
                phaseEnd: "alter-call-and-create-views"),
            .init("INSERT INTO ddlcompat.v VALUES(2,20)", restartBefore: true),
            .init(
                "ALTER ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.v AS (SELECT id,n FROM ddlcompat.t WHERE n>0) WITH CASCADED CHECK OPTION"
            ),
            .init("UPDATE ddlcompat.v SET n=21 WHERE id=2"),
            .init("DROP VIEW IF EXISTS ddlcompat.v,ddlcompat.v2,ddlcompat.absent CASCADE"),
            .init("DROP PROCEDURE IF EXISTS ddlcompat.p"),
            .init("DROP FUNCTION IF EXISTS ddlcompat.f", phaseEnd: "write-alter-and-drop-objects"),
            .init("DELETE FROM ddlcompat.t WHERE id=1", restartBefore: true),
            .init("CREATE DATABASE stored_alter_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE stored_alter_results.sa_original_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_original_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_original_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_original_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init("CREATE TABLE stored_alter_results.sa_procedure_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_procedure_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_procedure_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_procedure_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_procedure_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init("CREATE TABLE stored_alter_results.sa_function_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_function_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_function_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_function_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_function_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_function_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CREATE TABLE stored_alter_results.sa_called_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_called_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_called_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_called_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_called_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_called_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_called_p(1)"),
            .init("CREATE TABLE stored_alter_results.sa_local_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_local_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_local_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_local_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_local_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_local_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_local_p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_local_v(id,n) AS (SELECT id,n FROM stored_alter_results.sa_local_t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init("CREATE TABLE stored_alter_results.sa_second_view_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_second_view_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_second_view_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_second_view_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_second_view_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_second_view_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_second_view_p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_second_view_v(id,n) AS (SELECT id,n FROM stored_alter_results.sa_second_view_t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_second_view_v2 AS (SELECT id,n FROM stored_alter_results.sa_second_view_t)"
            ),
            .init("CREATE TABLE stored_alter_results.sa_inserted_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_inserted_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_inserted_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_inserted_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_inserted_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_inserted_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_inserted_p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_inserted_v(id,n) AS (SELECT id,n FROM stored_alter_results.sa_inserted_t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_inserted_v2 AS (SELECT id,n FROM stored_alter_results.sa_inserted_t)"
            ),
            .init("INSERT INTO stored_alter_results.sa_inserted_v VALUES(2,20)"),
            .init("CREATE TABLE stored_alter_results.sa_cascaded_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_cascaded_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_cascaded_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_cascaded_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_cascaded_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_cascaded_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_cascaded_p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_cascaded_v(id,n) AS (SELECT id,n FROM stored_alter_results.sa_cascaded_t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_cascaded_v2 AS (SELECT id,n FROM stored_alter_results.sa_cascaded_t)"
            ),
            .init("INSERT INTO stored_alter_results.sa_cascaded_v VALUES(2,20)"),
            .init(
                "ALTER ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW stored_alter_results.sa_cascaded_v AS (SELECT id,n FROM stored_alter_results.sa_cascaded_t WHERE n>0) WITH CASCADED CHECK OPTION"
            ),
            .init("CREATE TABLE stored_alter_results.sa_updated_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE stored_alter_results.sa_updated_p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO stored_alter_results.sa_updated_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION stored_alter_results.sa_updated_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "ALTER PROCEDURE stored_alter_results.sa_updated_p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
            ),
            .init(
                "ALTER FUNCTION stored_alter_results.sa_updated_f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'"
            ),
            .init("CALL stored_alter_results.sa_updated_p(1)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_updated_v(id,n) AS (SELECT id,n FROM stored_alter_results.sa_updated_t WHERE n>0) WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW stored_alter_results.sa_updated_v2 AS (SELECT id,n FROM stored_alter_results.sa_updated_t)"
            ),
            .init("INSERT INTO stored_alter_results.sa_updated_v VALUES(2,20)"),
            .init(
                "ALTER ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW stored_alter_results.sa_updated_v AS (SELECT id,n FROM stored_alter_results.sa_updated_t WHERE n>0) WITH CASCADED CHECK OPTION"
            ),
            .init(
                "UPDATE stored_alter_results.sa_updated_v SET n=21 WHERE id=2", phaseEnd: "delete-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "altered-procedure-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_procedure_p'",
                        "root@localhost\tINVOKER\tMODIFIES SQL DATA\tupdated procedure")),
                .init(
                    id: "altered-function-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,IS_DETERMINISTIC,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_function_f'",
                        "root@localhost\tINVOKER\tREADS SQL DATA\tYES\tupdated function")),
                .init(id: "function-result", check: .init("SELECT stored_alter_results.sa_function_f(7)", "8")),
                .init(
                    id: "procedure-call-rows", check: .init("SELECT * FROM stored_alter_results.sa_called_t", "1\t11")),
                .init(
                    id: "local-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_alter_results' AND TABLE_NAME='sa_local_v'",
                        "root@localhost\tINVOKER\tLOCAL\tYES")),
                .init(
                    id: "insert-through-view-rows",
                    check: .init("SELECT * FROM stored_alter_results.sa_inserted_t ORDER BY id", "1\t11\n2\t20")),
                .init(
                    id: "cascaded-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_alter_results' AND TABLE_NAME='sa_cascaded_v'",
                        "root@localhost\tDEFINER\tCASCADED\tYES")),
                .init(
                    id: "update-through-view-rows",
                    check: .init("SELECT * FROM stored_alter_results.sa_updated_v2 ORDER BY id", "1\t11\n2\t21")),
                .init(
                    id: "original-views-dropped",
                    check: .init("SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'", "0")),
                .init(
                    id: "original-routines-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'", "0")),
                .init(id: "original-delete-rows", check: .init("SELECT * FROM ddlcompat.t", "2\t21")),
                .init(
                    id: "original-procedure-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_original_p'",
                        "root@localhost\tDEFINER\tMODIFIES SQL DATA\toriginal")),
                .init(
                    id: "original-function-security",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_original_f'",
                        "root@localhost\tDEFINER")),
                .init(
                    id: "before-call-empty",
                    check: .init("SELECT COUNT(*) FROM stored_alter_results.sa_function_t", "0")),
                .init(id: "local-view-rows", check: .init("SELECT * FROM stored_alter_results.sa_local_v", "1\t11")),
                .init(
                    id: "second-view-rows",
                    check: .init("SELECT * FROM stored_alter_results.sa_second_view_v2", "1\t11")),
                .init(
                    id: "before-update-rows",
                    check: .init("SELECT * FROM stored_alter_results.sa_cascaded_t ORDER BY id", "1\t11\n2\t20")),
                .init(
                    id: "before-delete-rows",
                    check: .init("SELECT * FROM stored_alter_results.sa_updated_t ORDER BY id", "1\t11\n2\t21")),
                .init(
                    id: "retained-routine-count",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results'",
                        "18")),
                .init(
                    id: "retained-view-count",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_alter_results'", "9")),
            ], databases: ["ddlcompat", "stored_alter_results"],
            cleanup: ["DROP DATABASE stored_alter_results"]
        ))
}
