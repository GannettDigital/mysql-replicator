import Foundation

extension DDLCompatibilityCases {
    static let alterTableRename = Case(
        "alter-table-rename", "Compound ALTER renames, FK peers, cross-schema moves, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.child(cid INT PRIMARY KEY,pid INT,CONSTRAINT child_fk FOREIGN KEY(pid) REFERENCES ddlcompat.parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.parent ADD n INT DEFAULT 7", phaseEnd: "prepare-original-pair"),
            .init("ALTER TABLE ddlcompat.parent RENAME TO otherdb.moved,CHANGE id new_id INT", restartBefore: true),
            .init(
                "UPDATE otherdb.moved SET a=11 WHERE new_id=1",
                sqlTransactional: "UPDATE otherdb.moved SET new_id=2,a=11 WHERE new_id=1",
                phaseEnd: "move-and-update-parent"),
            .init("ALTER TABLE ddlcompat.child ADD note INT DEFAULT 3,RENAME AS otherdb.kid", restartBefore: true),
            .init(
                "ALTER TABLE otherdb.kid MODIFY note BIGINT,RENAME ddlcompat.child",
                sqlTransactional:
                    "ALTER TABLE otherdb.kid RENAME ddlcompat.child,DROP FOREIGN KEY child_fk,ADD CONSTRAINT new_fk FOREIGN KEY(pid) REFERENCES otherdb.moved(new_id) ON UPDATE CASCADE,MODIFY note BIGINT",
                phaseEnd: "move-and-return-child"),
            .init(
                "ALTER TABLE otherdb.moved RENAME otherdb.unused_name,MODIFY note VARCHAR(30),RENAME TO ddlcompat.parent",
                restartBefore: true),
            .init("ALTER TABLE ddlcompat.parent ADD flag INT DEFAULT 9,RENAME TO ddlcompat.parent"),
            .init(
                "UPDATE ddlcompat.parent SET n=8", sqlTransactional: "UPDATE ddlcompat.parent SET new_id=3,n=8",
                phaseEnd: "return-and-update-parent"),
            .init("ALTER TABLE ddlcompat.child RENAME AS ddlcompat.temporary_child", restartBefore: true),
            .init("ALTER TABLE ddlcompat.temporary_child RENAME ddlcompat.child"),
            .init("DELETE FROM ddlcompat.child WHERE cid=10"),
            .init("DELETE FROM ddlcompat.parent"),
            .init("DROP TABLE ddlcompat.child,ddlcompat.parent"),
            // Retain the ar_move endpoint for the final comparison.
            .init(
                "CREATE TABLE ddlcompat.ar_move_parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.ar_move_child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.ar_move_child(cid INT PRIMARY KEY,pid INT,CONSTRAINT ar_move_fk FOREIGN KEY(pid) REFERENCES ddlcompat.ar_move_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.ar_move_parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.ar_move_child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.ar_move_parent ADD n INT DEFAULT 7"),
            .init("ALTER TABLE ddlcompat.ar_move_parent RENAME TO otherdb.ar_move_moved,CHANGE id new_id INT"),
            // Retain the ar_child endpoint for the final comparison.
            .init(
                "CREATE TABLE ddlcompat.ar_child_parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.ar_child_child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.ar_child_child(cid INT PRIMARY KEY,pid INT,CONSTRAINT ar_child_fk FOREIGN KEY(pid) REFERENCES ddlcompat.ar_child_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.ar_child_parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.ar_child_child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.ar_child_parent ADD n INT DEFAULT 7"),
            .init("ALTER TABLE ddlcompat.ar_child_parent RENAME TO otherdb.ar_child_moved,CHANGE id new_id INT"),
            .init(
                "UPDATE otherdb.ar_child_moved SET a=11 WHERE new_id=1",
                sqlTransactional: "UPDATE otherdb.ar_child_moved SET new_id=2,a=11 WHERE new_id=1"),
            .init("ALTER TABLE ddlcompat.ar_child_child ADD note INT DEFAULT 3,RENAME AS otherdb.ar_child_kid"),
            // Retain the ar_return endpoint for the final comparison.
            .init(
                "CREATE TABLE ddlcompat.ar_return_parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.ar_return_child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.ar_return_child(cid INT PRIMARY KEY,pid INT,CONSTRAINT ar_return_fk FOREIGN KEY(pid) REFERENCES ddlcompat.ar_return_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.ar_return_parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.ar_return_child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.ar_return_parent ADD n INT DEFAULT 7"),
            .init("ALTER TABLE ddlcompat.ar_return_parent RENAME TO otherdb.ar_return_moved,CHANGE id new_id INT"),
            .init(
                "UPDATE otherdb.ar_return_moved SET a=11 WHERE new_id=1",
                sqlTransactional: "UPDATE otherdb.ar_return_moved SET new_id=2,a=11 WHERE new_id=1"),
            .init("ALTER TABLE ddlcompat.ar_return_child ADD note INT DEFAULT 3,RENAME AS otherdb.ar_return_kid"),
            .init(
                "ALTER TABLE otherdb.ar_return_kid MODIFY note BIGINT,RENAME ddlcompat.ar_return_child",
                sqlTransactional:
                    "ALTER TABLE otherdb.ar_return_kid RENAME ddlcompat.ar_return_child,DROP FOREIGN KEY ar_return_fk,ADD CONSTRAINT ar_return_new_fk FOREIGN KEY(pid) REFERENCES otherdb.ar_return_moved(new_id) ON UPDATE CASCADE,MODIFY note BIGINT"
            ),
            .init(
                "ALTER TABLE otherdb.ar_return_moved RENAME otherdb.ar_return_unused,MODIFY note VARCHAR(30),RENAME TO ddlcompat.ar_return_parent"
            ),
            // Retain the ar_final endpoint for the final comparison.
            .init(
                "CREATE TABLE ddlcompat.ar_final_parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.ar_final_child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.ar_final_child(cid INT PRIMARY KEY,pid INT,CONSTRAINT ar_final_fk FOREIGN KEY(pid) REFERENCES ddlcompat.ar_final_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.ar_final_parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.ar_final_child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.ar_final_parent ADD n INT DEFAULT 7"),
            .init("ALTER TABLE ddlcompat.ar_final_parent RENAME TO otherdb.ar_final_moved,CHANGE id new_id INT"),
            .init(
                "UPDATE otherdb.ar_final_moved SET a=11 WHERE new_id=1",
                sqlTransactional: "UPDATE otherdb.ar_final_moved SET new_id=2,a=11 WHERE new_id=1"),
            .init("ALTER TABLE ddlcompat.ar_final_child ADD note INT DEFAULT 3,RENAME AS otherdb.ar_final_kid"),
            .init(
                "ALTER TABLE otherdb.ar_final_kid MODIFY note BIGINT,RENAME ddlcompat.ar_final_child",
                sqlTransactional:
                    "ALTER TABLE otherdb.ar_final_kid RENAME ddlcompat.ar_final_child,DROP FOREIGN KEY ar_final_fk,ADD CONSTRAINT ar_final_new_fk FOREIGN KEY(pid) REFERENCES otherdb.ar_final_moved(new_id) ON UPDATE CASCADE,MODIFY note BIGINT"
            ),
            .init(
                "ALTER TABLE otherdb.ar_final_moved RENAME otherdb.ar_final_unused,MODIFY note VARCHAR(30),RENAME TO ddlcompat.ar_final_parent"
            ),
            .init("ALTER TABLE ddlcompat.ar_final_parent ADD flag INT DEFAULT 9,RENAME TO ddlcompat.ar_final_parent"),
            .init(
                "UPDATE ddlcompat.ar_final_parent SET n=8",
                sqlTransactional: "UPDATE ddlcompat.ar_final_parent SET new_id=3,n=8",
                phaseEnd: "drop-original-and-retain-endpoints"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "moved-parent-default-and-row",
                    check: .init("SELECT new_id,a,n FROM otherdb.ar_move_moved", "1\t10\t7")),
                .init(
                    id: "moved-parent-child-row",
                    check: .init(
                        "SELECT c.cid,c.pid,p.new_id FROM ddlcompat.ar_move_child c JOIN otherdb.ar_move_moved p ON c.pid=p.new_id",
                        "10\t1\t1")),
                .init(id: "moved-child-default", check: .init("SELECT cid,note FROM otherdb.ar_child_kid", "10\t3")),
                .init(
                    id: "cascade-after-parent-move",
                    check: .init(
                        "SELECT p.new_id,p.a,c.pid FROM otherdb.ar_child_moved p JOIN otherdb.ar_child_kid c ON c.pid=p.new_id",
                        "1\t11\t1"),
                    transactionalCheck: .init(
                        "SELECT p.new_id,p.a,c.pid FROM otherdb.ar_child_moved p JOIN otherdb.ar_child_kid c ON c.pid=p.new_id",
                        "2\t11\t2")),
                .init(
                    id: "returned-parent-default", check: .init("SELECT a,n FROM ddlcompat.ar_return_parent", "11\t7")),
                .init(
                    id: "returned-child-definition",
                    check: .init(
                        "SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ar_return_child' AND COLUMN_NAME='note'",
                        "bigint")),
                .init(
                    id: "same-name-rename-and-following-update",
                    check: .init(
                        "SELECT p.new_id,p.n,p.flag,c.pid FROM ddlcompat.ar_final_parent p JOIN ddlcompat.ar_final_child c ON c.pid=p.new_id",
                        "1\t8\t9\t1"),
                    transactionalCheck: .init(
                        "SELECT p.new_id,p.n,p.flag,c.pid FROM ddlcompat.ar_final_parent p JOIN ddlcompat.ar_final_child c ON c.pid=p.new_id",
                        "3\t8\t9\t3")),
                .init(
                    id: "original-and-temporary-tables-absent",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE (TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('parent','child','temporary_child')) OR (TABLE_SCHEMA='otherdb' AND TABLE_NAME IN ('moved','kid','unused_name','ar_return_moved','ar_return_kid','ar_return_unused','ar_final_moved','ar_final_kid','ar_final_unused'))",
                        "0")),
                .init(
                    id: "replacement-foreign-key",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='ddlcompat' AND TABLE_NAME='ar_return_child'",
                        "0"),
                    transactionalCheck: .init(
                        "SELECT CONSTRAINT_NAME,REFERENCED_TABLE_NAME,UPDATE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='ddlcompat' AND TABLE_NAME='ar_return_child'",
                        "ar_return_new_fk\tar_return_parent\tCASCADE")),
            ], databases: ["ddlcompat", "otherdb"],
            cleanup: [
                "DROP TABLE ddlcompat.ar_move_child,otherdb.ar_child_kid,ddlcompat.ar_return_child,ddlcompat.ar_final_child,otherdb.ar_move_moved,otherdb.ar_child_moved,ddlcompat.ar_return_parent,ddlcompat.ar_final_parent"
            ]))
}

extension SharedCorrectness.Run {
    func rejectUnsafeTarget84Rename() throws {
        guard f.profile == .reverse, selects("alter-rename-target84-refusal") else { return }
        try reporter.run(
            .init("alter-rename-target84-refusal", "Refuse a native 8.4 parent rename defect before target SQL")
        ) {
            let setup =
                "SET sql_log_bin=0;CREATE DATABASE rename_refusal;CREATE TABLE rename_refusal.p(id INT PRIMARY KEY);CREATE TABLE rename_refusal.c(id INT PRIMARY KEY,p INT,CONSTRAINT fk FOREIGN KEY(p) REFERENCES rename_refusal.p(id) ON UPDATE CASCADE);INSERT INTO rename_refusal.p VALUES(1);INSERT INTO rename_refusal.c VALUES(1,1)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, setup) }
            let isolated = LabIsolatedApply(f)
            let label = "rename-native84-refusal"
            let start = try f.boundary()
            let config = isolated.configuration(label, at: start, count: 1)
            _ = try f.sql(
                .source,
                session
                    + "ALTER TABLE rename_refusal.p RENAME rename_refusal.moved,CHANGE id new_id INT,ADD n INT DEFAULT 7"
            )
            try f.awaitNative()
            let client = try isolated.start(label, config: config)
            let result = try isolated.finish(
                client, label: label, config: config, reason: "target MySQL 8.4 native ALTER limitation")
            let progress = result["progress"] as? [String: Any]
            let failure = progress?["targetFailure"] as? [String: Any]
            let statement = failure?["statement"] as? [String: Any]
            try require(statement?["phase"] as? String == "notIssued", "unsafe native ALTER reached the target")
            try require(
                isolated.state(label, "SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0",
                "native ALTER refusal advanced progress")
            try require(
                f.sql(.target, "SELECT id FROM rename_refusal.p") == "1", "native ALTER refusal changed target rows")
            try require(
                f.sql(
                    .target,
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='rename_refusal' AND TABLE_NAME='moved'"
                ) == "0", "native ALTER refusal renamed the target")
        }
    }
}
