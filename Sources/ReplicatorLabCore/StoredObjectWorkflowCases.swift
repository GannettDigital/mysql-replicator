import Foundation

extension DDLCompatibilityCases {
    static let viewLifecycle = Case(
        "views", "Views: CREATE OR REPLACE, ALTER and base-table row effects",
        [
            // Keep the original operations first; retain objects outside ddlcompat.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n FROM ddlcompat.t"),
            .init("INSERT INTO ddlcompat.v VALUES(1,7)"),
            .init("CREATE OR REPLACE SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n+1 AS n FROM ddlcompat.t"),
            .init("ALTER SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n+2 AS n FROM ddlcompat.t"),
            .init("DROP VIEW ddlcompat.v"),
            .init("CREATE DATABASE stored_view_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE stored_view_results.sv_initial_base(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW stored_view_results.sv_initial AS SELECT id,n FROM stored_view_results.sv_initial_base"
            ),
            .init("INSERT INTO stored_view_results.sv_initial VALUES(1,7)"),
            .init("CREATE TABLE stored_view_results.sv_replaced_base(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW stored_view_results.sv_replaced AS SELECT id,n FROM stored_view_results.sv_replaced_base"
            ),
            .init("INSERT INTO stored_view_results.sv_replaced VALUES(1,7)"),
            .init(
                "CREATE OR REPLACE SQL SECURITY INVOKER VIEW stored_view_results.sv_replaced AS SELECT id,n+1 AS n FROM stored_view_results.sv_replaced_base"
            ),
            .init("CREATE TABLE stored_view_results.sv_altered_base(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW stored_view_results.sv_altered AS SELECT id,n FROM stored_view_results.sv_altered_base"
            ),
            .init("INSERT INTO stored_view_results.sv_altered VALUES(1,7)"),
            .init(
                "CREATE OR REPLACE SQL SECURITY INVOKER VIEW stored_view_results.sv_altered AS SELECT id,n+1 AS n FROM stored_view_results.sv_altered_base"
            ),
            .init(
                "ALTER SQL SECURITY INVOKER VIEW stored_view_results.sv_altered AS SELECT id,n+2 AS n FROM stored_view_results.sv_altered_base",
                phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(id: "original-view-rows", check: .init("SELECT * FROM stored_view_results.sv_initial", "1\t7")),
                .init(id: "replaced-view-rows", check: .init("SELECT * FROM stored_view_results.sv_replaced", "1\t8")),
                .init(id: "altered-view-rows", check: .init("SELECT * FROM stored_view_results.sv_altered", "1\t9")),
                .init(
                    id: "original-views-dropped",
                    check: .init("SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'", "0")),
                .init(
                    id: "initial-base-rows",
                    check: .init("SELECT id,n FROM stored_view_results.sv_initial_base", "1\t7")),
                .init(
                    id: "replaced-base-rows",
                    check: .init("SELECT id,n FROM stored_view_results.sv_replaced_base", "1\t7")),
                .init(
                    id: "altered-base-rows",
                    check: .init("SELECT id,n FROM stored_view_results.sv_altered_base", "1\t7")),
                .init(
                    id: "retained-view-security",
                    check: .init(
                        "SELECT TABLE_NAME,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_view_results' ORDER BY TABLE_NAME",
                        "sv_altered\tINVOKER\nsv_initial\tINVOKER\nsv_replaced\tINVOKER")),
                .init(id: "original-base-rows", check: .init("SELECT id,n FROM ddlcompat.t", "1\t7")),
            ], databases: ["ddlcompat", "stored_view_results"],
            cleanup: ["DROP DATABASE stored_view_results"]
        ))

    static let routineLifecycle = Case(
        "routines", "Stored routines: compound procedure, function and row effects",
        [
            // Keep the original operations first; retain objects outside ddlcompat.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE PROCEDURE ddlcompat.p(IN k INT) SQL SECURITY INVOKER BEGIN DECLARE v INT; SET v=k+1; INSERT INTO ddlcompat.t VALUES(k,v); END"
            ),
            .init(
                "CREATE FUNCTION ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+1"),
            .init("CALL ddlcompat.p(1)"),
            .init("DROP PROCEDURE ddlcompat.p"),
            .init("DROP FUNCTION ddlcompat.f"),
            .init("CREATE DATABASE stored_routine_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE stored_routine_results.sr_created_base(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE PROCEDURE stored_routine_results.sr_created_p(IN k INT) SQL SECURITY INVOKER BEGIN DECLARE v INT; SET v=k+1; INSERT INTO stored_routine_results.sr_created_base VALUES(k,v); END"
            ),
            .init("CREATE TABLE stored_routine_results.sr_function_base(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE PROCEDURE stored_routine_results.sr_function_p(IN k INT) SQL SECURITY INVOKER BEGIN DECLARE v INT; SET v=k+1; INSERT INTO stored_routine_results.sr_function_base VALUES(k,v); END"
            ),
            .init(
                "CREATE FUNCTION stored_routine_results.sr_function_f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+1",
                phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "procedure-create-does-not-execute",
                    check: .init("SELECT COUNT(*) FROM stored_routine_results.sr_created_base", "0")),
                .init(
                    id: "retained-function-result", check: .init("SELECT stored_routine_results.sr_function_f(7)", "8")),
                .init(id: "original-call-result", check: .init("SELECT * FROM ddlcompat.t", "1\t2")),
                .init(
                    id: "original-routines-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'", "0")),
                .init(
                    id: "function-create-does-not-write",
                    check: .init("SELECT COUNT(*) FROM stored_routine_results.sr_function_base", "0")),
                .init(
                    id: "retained-routine-metadata",
                    check: .init(
                        "SELECT ROUTINE_NAME,ROUTINE_TYPE,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_routine_results' ORDER BY ROUTINE_NAME",
                        "sr_created_p\tPROCEDURE\tINVOKER\nsr_function_f\tFUNCTION\tINVOKER\nsr_function_p\tPROCEDURE\tINVOKER"
                    )),
            ], databases: ["ddlcompat", "stored_routine_results"],
            cleanup: ["DROP DATABASE stored_routine_results"]
        ))

}
