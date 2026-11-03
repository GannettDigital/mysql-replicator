import Foundation

extension DDLCompatibilityCases {
    static let viewRenames = Case(
        "view-renames", "RENAME TABLE: views, table/view swaps and row effects",
        [
            // Preserve the complete original rename statements before independent histories.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10)"),
            .init("CREATE TABLE ddlcompat.aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n FROM ddlcompat.t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW ddlcompat.v2 AS SELECT id,n+1 AS n FROM ddlcompat.t",
                phaseEnd: "create-base-tables-and-views"),
            .init("RENAME TABLE ddlcompat.v TO ddlcompat.renamed", restartBefore: true),
            .init(
                "RENAME TABLE ddlcompat.renamed TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.renamed,ddlcompat.tmp TO ddlcompat.v2",
                phaseEnd: "rename-and-swap-views"),
            .init(
                "RENAME TABLE ddlcompat.aux TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.aux,ddlcompat.tmp TO ddlcompat.v2",
                restartBefore: true),
            .init("UPDATE ddlcompat.v2 SET n=21 WHERE id=2"),
            .init("INSERT INTO ddlcompat.aux VALUES(3,30)"),
            .init(
                "RENAME TABLE ddlcompat.v2 TO ddlcompat.moved,ddlcompat.aux TO ddlcompat.final_view",
                phaseEnd: "swap-types-and-rename"),
            .init("DELETE FROM ddlcompat.moved WHERE id=2", restartBefore: true),
            .init("CREATE DATABASE view_rename_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE view_rename_results.vr_seed_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_seed_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_seed_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_seed_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_seed_v AS SELECT id,n FROM view_rename_results.vr_seed_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_seed_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_seed_t"
            ),
            .init("CREATE TABLE view_rename_results.vr_renamed_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_renamed_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_renamed_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_renamed_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_renamed_v AS SELECT id,n FROM view_rename_results.vr_renamed_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_renamed_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_renamed_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_renamed_v TO view_rename_results.vr_renamed_renamed"),
            .init("CREATE TABLE view_rename_results.vr_swapped_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_swapped_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_swapped_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_swapped_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_swapped_v AS SELECT id,n FROM view_rename_results.vr_swapped_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_swapped_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_swapped_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_swapped_v TO view_rename_results.vr_swapped_renamed"),
            .init(
                "RENAME TABLE view_rename_results.vr_swapped_renamed TO view_rename_results.vr_swapped_tmp,view_rename_results.vr_swapped_v2 TO view_rename_results.vr_swapped_renamed,view_rename_results.vr_swapped_tmp TO view_rename_results.vr_swapped_v2"
            ),
            .init("CREATE TABLE view_rename_results.vr_mixed_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_mixed_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_mixed_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_mixed_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_mixed_v AS SELECT id,n FROM view_rename_results.vr_mixed_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_mixed_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_mixed_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_mixed_v TO view_rename_results.vr_mixed_renamed"),
            .init(
                "RENAME TABLE view_rename_results.vr_mixed_renamed TO view_rename_results.vr_mixed_tmp,view_rename_results.vr_mixed_v2 TO view_rename_results.vr_mixed_renamed,view_rename_results.vr_mixed_tmp TO view_rename_results.vr_mixed_v2"
            ),
            .init(
                "RENAME TABLE view_rename_results.vr_mixed_aux TO view_rename_results.vr_mixed_tmp,view_rename_results.vr_mixed_v2 TO view_rename_results.vr_mixed_aux,view_rename_results.vr_mixed_tmp TO view_rename_results.vr_mixed_v2"
            ),
            .init("CREATE TABLE view_rename_results.vr_updated_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_updated_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_updated_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_updated_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_updated_v AS SELECT id,n FROM view_rename_results.vr_updated_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_updated_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_updated_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_updated_v TO view_rename_results.vr_updated_renamed"),
            .init(
                "RENAME TABLE view_rename_results.vr_updated_renamed TO view_rename_results.vr_updated_tmp,view_rename_results.vr_updated_v2 TO view_rename_results.vr_updated_renamed,view_rename_results.vr_updated_tmp TO view_rename_results.vr_updated_v2"
            ),
            .init(
                "RENAME TABLE view_rename_results.vr_updated_aux TO view_rename_results.vr_updated_tmp,view_rename_results.vr_updated_v2 TO view_rename_results.vr_updated_aux,view_rename_results.vr_updated_tmp TO view_rename_results.vr_updated_v2"
            ),
            .init("UPDATE view_rename_results.vr_updated_v2 SET n=21 WHERE id=2"),
            .init("CREATE TABLE view_rename_results.vr_inserted_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_inserted_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_inserted_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_inserted_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_inserted_v AS SELECT id,n FROM view_rename_results.vr_inserted_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_inserted_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_inserted_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_inserted_v TO view_rename_results.vr_inserted_renamed"),
            .init(
                "RENAME TABLE view_rename_results.vr_inserted_renamed TO view_rename_results.vr_inserted_tmp,view_rename_results.vr_inserted_v2 TO view_rename_results.vr_inserted_renamed,view_rename_results.vr_inserted_tmp TO view_rename_results.vr_inserted_v2"
            ),
            .init(
                "RENAME TABLE view_rename_results.vr_inserted_aux TO view_rename_results.vr_inserted_tmp,view_rename_results.vr_inserted_v2 TO view_rename_results.vr_inserted_aux,view_rename_results.vr_inserted_tmp TO view_rename_results.vr_inserted_v2"
            ),
            .init("UPDATE view_rename_results.vr_inserted_v2 SET n=21 WHERE id=2"),
            .init("INSERT INTO view_rename_results.vr_inserted_aux VALUES(3,30)"),
            .init("CREATE TABLE view_rename_results.vr_final_names_t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_final_names_t VALUES(1,10)"),
            .init("CREATE TABLE view_rename_results.vr_final_names_aux(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO view_rename_results.vr_final_names_aux VALUES(2,20)"),
            .init(
                "CREATE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW view_rename_results.vr_final_names_v AS SELECT id,n FROM view_rename_results.vr_final_names_t WHERE n>0 WITH LOCAL CHECK OPTION"
            ),
            .init(
                "CREATE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW view_rename_results.vr_final_names_v2 AS SELECT id,n+1 AS n FROM view_rename_results.vr_final_names_t"
            ),
            .init("RENAME TABLE view_rename_results.vr_final_names_v TO view_rename_results.vr_final_names_renamed"),
            .init(
                "RENAME TABLE view_rename_results.vr_final_names_renamed TO view_rename_results.vr_final_names_tmp,view_rename_results.vr_final_names_v2 TO view_rename_results.vr_final_names_renamed,view_rename_results.vr_final_names_tmp TO view_rename_results.vr_final_names_v2"
            ),
            .init(
                "RENAME TABLE view_rename_results.vr_final_names_aux TO view_rename_results.vr_final_names_tmp,view_rename_results.vr_final_names_v2 TO view_rename_results.vr_final_names_aux,view_rename_results.vr_final_names_tmp TO view_rename_results.vr_final_names_v2"
            ),
            .init("UPDATE view_rename_results.vr_final_names_v2 SET n=21 WHERE id=2"),
            .init("INSERT INTO view_rename_results.vr_final_names_aux VALUES(3,30)"),
            .init(
                "RENAME TABLE view_rename_results.vr_final_names_v2 TO view_rename_results.vr_final_names_moved,view_rename_results.vr_final_names_aux TO view_rename_results.vr_final_names_final_view",
                phaseEnd: "delete-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "single-rename-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_renamed_renamed", "1\t10")),
                .init(
                    id: "single-rename-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME='vr_renamed_renamed'",
                        "root@localhost\tINVOKER\tLOCAL")),
                .init(
                    id: "swapped-definer-view-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_swapped_renamed", "1\t11")),
                .init(
                    id: "swapped-invoker-view-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_swapped_v2", "1\t10")),
                .init(id: "mixed-view-rows", check: .init("SELECT * FROM view_rename_results.vr_mixed_aux", "1\t10")),
                .init(id: "mixed-base-rows", check: .init("SELECT * FROM view_rename_results.vr_mixed_v2", "2\t20")),
                .init(
                    id: "updated-base-rows", check: .init("SELECT * FROM view_rename_results.vr_updated_v2", "2\t21")),
                .init(
                    id: "insert-through-view-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_inserted_t ORDER BY id", "1\t10\n3\t30")),
                .init(
                    id: "final-view-rows",
                    check: .init(
                        "SELECT * FROM view_rename_results.vr_final_names_final_view ORDER BY id", "1\t10\n3\t30")),
                .init(
                    id: "final-view-metadata",
                    check: .init(
                        "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME='vr_final_names_final_view'",
                        "root@localhost\tINVOKER\tLOCAL")),
                .init(id: "deleted-moved-table-empty", check: .init("SELECT COUNT(*) FROM ddlcompat.moved", "0")),
                .init(id: "seed-invoker-view", check: .init("SELECT * FROM view_rename_results.vr_seed_v", "1\t10")),
                .init(id: "seed-definer-view", check: .init("SELECT * FROM view_rename_results.vr_seed_v2", "1\t11")),
                .init(
                    id: "seed-view-security",
                    check: .init(
                        "SELECT TABLE_NAME,DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME IN ('vr_seed_v','vr_seed_v2') ORDER BY TABLE_NAME",
                        "vr_seed_v\troot@localhost\tINVOKER\tLOCAL\nvr_seed_v2\troot@localhost\tDEFINER\tNONE")),
                .init(
                    id: "inserted-computed-view-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_inserted_renamed ORDER BY id", "1\t11\n3\t31")),
                .init(
                    id: "before-delete-moved-rows",
                    check: .init("SELECT * FROM view_rename_results.vr_final_names_moved", "2\t21")),
                .init(
                    id: "object-types-after-8",
                    check: .init(
                        "SELECT TABLE_NAME,TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME IN ('vr_swapped_renamed','vr_swapped_v2','vr_swapped_t','vr_swapped_aux') ORDER BY TABLE_NAME",
                        "vr_swapped_aux\tBASE TABLE\nvr_swapped_renamed\tVIEW\nvr_swapped_t\tBASE TABLE\nvr_swapped_v2\tVIEW"
                    )),
                .init(
                    id: "object-types-after-9",
                    check: .init(
                        "SELECT TABLE_NAME,TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME IN ('vr_mixed_renamed','vr_mixed_aux','vr_mixed_t','vr_mixed_v2') ORDER BY TABLE_NAME",
                        "vr_mixed_aux\tVIEW\nvr_mixed_renamed\tVIEW\nvr_mixed_t\tBASE TABLE\nvr_mixed_v2\tBASE TABLE")),
                .init(
                    id: "object-types-after-12",
                    check: .init(
                        "SELECT TABLE_NAME,TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME IN ('vr_final_names_renamed','vr_final_names_final_view','vr_final_names_t','vr_final_names_moved') ORDER BY TABLE_NAME",
                        "vr_final_names_final_view\tVIEW\nvr_final_names_moved\tBASE TABLE\nvr_final_names_renamed\tVIEW\nvr_final_names_t\tBASE TABLE"
                    )),
            ], databases: ["ddlcompat", "view_rename_results"],
            cleanup: ["DROP DATABASE view_rename_results"]
        ))
}

enum ViewRenameWorkflowEvidence {
    static func sqliteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static var originalJournalSQL: String {
        let statements = DDLCompatibilityCases.viewRenames.steps.prefix(13).filter {
            $0.sql.hasPrefix("RENAME TABLE ")
        }.map { sqliteLiteral($0.sql) }.joined(separator: ",")
        return
            "SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE status='DONE' AND json_array_length(context_json,'$.viewTransitions')>0 AND source_sql IN ("
            + statements + ")"
    }
    static let retainedViews = [
        "vr_seed_v",
        "vr_seed_v2",
        "vr_renamed_renamed",
        "vr_renamed_v2",
        "vr_swapped_renamed",
        "vr_swapped_v2",
        "vr_mixed_renamed",
        "vr_mixed_aux",
        "vr_updated_renamed",
        "vr_updated_aux",
        "vr_inserted_renamed",
        "vr_inserted_aux",
        "vr_final_names_renamed",
        "vr_final_names_final_view",
    ]
    static let retainedBaseTables = [
        "vr_seed_t",
        "vr_seed_aux",
        "vr_renamed_t",
        "vr_renamed_aux",
        "vr_swapped_t",
        "vr_swapped_aux",
        "vr_mixed_t",
        "vr_mixed_v2",
        "vr_updated_t",
        "vr_updated_v2",
        "vr_inserted_t",
        "vr_inserted_v2",
        "vr_final_names_t",
        "vr_final_names_moved",
    ]
    static func cacheSQL(_ names: [String]) -> String {
        "SELECT COUNT(*) FROM schemas WHERE current=1 AND json_extract(schema_json,'$.database')='view_rename_results' AND json_extract(schema_json,'$.table') IN ("
            + names.map { sqliteLiteral($0) }.joined(separator: ",") + ")"
    }
}
