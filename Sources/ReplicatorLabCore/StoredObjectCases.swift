import Foundation

extension DDLCompatibilityCases {
    static let conditionalRoutines = Case(
        "conditional-routines", "CREATE PROCEDURE/FUNCTION IF NOT EXISTS: existing routines and DROP/recreate",
        [
            // Original source operations keep their order, including skipped target DDL transactions.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO ddlcompat.t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1",
                phaseEnd: "create-original-routines"),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO ddlcompat.t VALUES(k,k+999)",
                restartBefore: true),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CALL ddlcompat.p(1)"),
            .init("DROP PROCEDURE ddlcompat.p", phaseEnd: "ignore-replacements-call-and-drop"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS ddlcompat.p(IN k INT) SQL SECURITY INVOKER INSERT INTO ddlcompat.t VALUES(k,k+20)",
                restartBefore: true),
            .init("CALL ddlcompat.p(2)"),
            .init("INSERT INTO ddlcompat.t VALUES(3,ddlcompat.f(7))"),
            .init("CREATE DATABASE conditional_routine_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE conditional_routine_results.cr_procedure_kept_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_procedure_kept_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_procedure_kept_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_procedure_kept_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_procedure_kept_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_procedure_kept_t VALUES(k,k+999)"
            ),
            .init("CREATE TABLE conditional_routine_results.cr_function_kept_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_function_kept_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_function_kept_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_function_kept_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_function_kept_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_function_kept_t VALUES(k,k+999)"
            ),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS conditional_routine_results.cr_function_kept_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CREATE TABLE conditional_routine_results.cr_called_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_called_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_called_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_called_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_called_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_called_t VALUES(k,k+999)"
            ),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS conditional_routine_results.cr_called_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CALL conditional_routine_results.cr_called_p(1)"),
            .init("CREATE TABLE conditional_routine_results.cr_dropped_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_dropped_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_dropped_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_dropped_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_dropped_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_dropped_t VALUES(k,k+999)"
            ),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS conditional_routine_results.cr_dropped_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CALL conditional_routine_results.cr_dropped_p(1)"),
            .init("DROP PROCEDURE conditional_routine_results.cr_dropped_p"),
            .init("CREATE TABLE conditional_routine_results.cr_recreated_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_recreated_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_recreated_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_recreated_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_recreated_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_recreated_t VALUES(k,k+999)"
            ),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS conditional_routine_results.cr_recreated_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CALL conditional_routine_results.cr_recreated_p(1)"),
            .init("DROP PROCEDURE conditional_routine_results.cr_recreated_p"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_recreated_p(IN k INT) SQL SECURITY INVOKER INSERT INTO conditional_routine_results.cr_recreated_t VALUES(k,k+20)"
            ),
            .init("CREATE TABLE conditional_routine_results.cr_called_new_t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_called_new_p(IN k INT) SQL SECURITY DEFINER COMMENT 'original' INSERT INTO conditional_routine_results.cr_called_new_t VALUES(k,k+10)"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' FUNCTION IF NOT EXISTS conditional_routine_results.cr_called_new_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY DEFINER RETURN k+1"
            ),
            .init(
                "CREATE DEFINER='root'@'%' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_called_new_p(IN k INT) SQL SECURITY INVOKER COMMENT 'replacement' INSERT INTO conditional_routine_results.cr_called_new_t VALUES(k,k+999)"
            ),
            .init(
                "CREATE DEFINER='root'@'%' FUNCTION IF NOT EXISTS conditional_routine_results.cr_called_new_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+999"
            ),
            .init("CALL conditional_routine_results.cr_called_new_p(1)"),
            .init("DROP PROCEDURE conditional_routine_results.cr_called_new_p"),
            .init(
                "CREATE DEFINER='root'@'localhost' PROCEDURE IF NOT EXISTS conditional_routine_results.cr_called_new_p(IN k INT) SQL SECURITY INVOKER INSERT INTO conditional_routine_results.cr_called_new_t VALUES(k,k+20)"
            ),
            .init("CALL conditional_routine_results.cr_called_new_p(2)", phaseEnd: "recreate-and-retain-results"),
        ],
        profileExclusions: [
            .reverse: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
            .mysql57MyISAM: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
            .mysql57InnoDB: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "existing-procedure-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_procedure_kept_p'",
                        "root@localhost\tDEFINER\toriginal")),
                .init(
                    id: "existing-function-result",
                    check: .init("SELECT conditional_routine_results.cr_function_kept_f(7)", "8")),
                .init(
                    id: "existing-function-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_function_kept_f'",
                        "root@localhost\tDEFINER")),
                .init(
                    id: "original-procedure-call-rows",
                    check: .init("SELECT * FROM conditional_routine_results.cr_called_t", "1\t11")),
                .init(
                    id: "recreated-procedure-call-rows",
                    check: .init(
                        "SELECT * FROM conditional_routine_results.cr_called_new_t ORDER BY id", "1\t11\n2\t22")),
                .init(
                    id: "final-insert-rows", check: .init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t11\n2\t22\n3\t8")
                ),
                .init(
                    id: "ignored-create-does-not-write",
                    check: .init("SELECT COUNT(*) FROM conditional_routine_results.cr_procedure_kept_t", "0")),
                .init(
                    id: "procedure-absent-after-drop",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_dropped_p'",
                        "0")),
                .init(
                    id: "function-survives-procedure-drop",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_dropped_f' AND ROUTINE_TYPE='FUNCTION'",
                        "1")),
                .init(
                    id: "rows-after-procedure-drop",
                    check: .init("SELECT * FROM conditional_routine_results.cr_dropped_t", "1\t11")),
                .init(
                    id: "recreated-procedure-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_recreated_p'",
                        "root@localhost\tINVOKER")),
                .init(
                    id: "rows-before-recreated-call",
                    check: .init("SELECT * FROM conditional_routine_results.cr_recreated_t", "1\t11")),
                .init(id: "original-function-still-preserved", check: .init("SELECT ddlcompat.f(7)", "8")),
                .init(
                    id: "retained-routine-count",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results'",
                        "11")),
            ], databases: ["ddlcompat", "conditional_routine_results"],
            cleanup: ["DROP DATABASE conditional_routine_results"]
        ))
}

enum ConditionalRoutineWorkflowEvidence {
    private static func originalSelection(_ writes: [LabSQLPhase.Result]) throws -> String {
        try require(writes.count >= 10, "conditional routine source results are incomplete")
        let gtids = try [1, 2, 3, 4, 7].map { index in
            let gtid = writes[index].gtids
            try require(
                try DMLCompatibilityCases.transactionCount(gtid) == 1,
                "conditional routine operation must have one source GTID")
            return LabSQLName.sqliteLiteral(gtid)
        }
        return "ddl_intents.gtid IN (" + gtids.joined(separator: ",") + ")"
    }
    static func compatibilitySQL(_ writes: [LabSQLPhase.Result]) throws -> String {
        "SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE status='DONE' AND json_extract(context_json,'$.nativeCompatibilityRules[0]')='mysql57-routine-create-if-not-exists' AND "
            + (try originalSelection(writes))
    }
    static func skippedSQL(_ writes: [LabSQLPhase.Result]) throws -> String {
        "SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE status='DONE' AND source_sql LIKE '%IF NOT EXISTS%' AND target_sql='' AND "
            + (try originalSelection(writes))
    }
}
