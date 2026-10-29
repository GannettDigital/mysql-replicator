import Foundation

extension DDLCompatibilityCases {
    static let multiTableDDL = Case(
        "multi-table", "Cross-schema moves and swaps, multi-table DROP, name reuse and restart",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,'first')"),
            .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.u VALUES(2,20)"),
            // Independent tables retain observations that the original DROP
            // and reuse sequence would erase before the final comparison.
            .init(
                "CREATE TABLE ddlcompat.mt_move(id INT PRIMARY KEY,n VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.mt_move VALUES(1,'first')"),
            .init(
                "CREATE TABLE ddlcompat.mt_update(id INT PRIMARY KEY,n VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.mt_update VALUES(1,'first')"),
            .init(
                "CREATE TABLE ddlcompat.mt_swap_t(id INT PRIMARY KEY,n VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.mt_swap_t VALUES(1,'first')"),
            .init("CREATE TABLE ddlcompat.mt_swap_u(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.mt_swap_u VALUES(2,20)", phaseEnd: "prepare-table-sets"),
            .init("RENAME TABLE ddlcompat.t TO otherdb.moved", restartBefore: true),
            .init("UPDATE otherdb.moved SET n='changed' WHERE id=1"),
            .init("RENAME TABLE ddlcompat.mt_move TO otherdb.mt_moved"),
            .init("RENAME TABLE ddlcompat.mt_update TO otherdb.mt_updated"),
            .init("UPDATE otherdb.mt_updated SET n='changed' WHERE id=1"),
            .init("RENAME TABLE ddlcompat.mt_swap_t TO otherdb.mt_swap_moved"),
            .init("UPDATE otherdb.mt_swap_moved SET n='changed' WHERE id=1", phaseEnd: "move-and-update"),
            .init(
                "RENAME TABLE otherdb.moved TO ddlcompat.spare,ddlcompat.u TO otherdb.moved,ddlcompat.spare TO ddlcompat.u",
                restartBefore: true),
            .init("CREATE TABLE otherdb.copy LIKE otherdb.moved"),
            .init("INSERT INTO otherdb.copy VALUES(3,30)"),
            .init(
                "RENAME TABLE otherdb.mt_swap_moved TO ddlcompat.mt_spare,ddlcompat.mt_swap_u TO otherdb.mt_swap_moved,ddlcompat.mt_spare TO ddlcompat.mt_swap_u"
            ),
            .init("CREATE TABLE otherdb.mt_copy LIKE otherdb.mt_swap_moved"),
            .init("INSERT INTO otherdb.mt_copy VALUES(3,30)"),
            .init("CREATE TABLE otherdb.mt_empty_copy LIKE otherdb.mt_swap_moved", phaseEnd: "swap-and-copy"),
            .init(
                "DROP TABLE ddlcompat.u,otherdb.moved,otherdb.copy RESTRICT",
                restartBefore: true, phaseEnd: "drop-three-tables"),
            .init("DROP TABLE IF EXISTS ddlcompat.u,otherdb.moved,otherdb.absent CASCADE", restartBefore: true),
            .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,n DECIMAL(10,2))", phaseEnd: "reuse-dropped-name"),
            .init("INSERT INTO ddlcompat.u VALUES(4,4.25)", restartBefore: true, phaseEnd: "write-reused-table"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "moved-table-encoding",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='otherdb' AND TABLE_NAME='mt_moved'",
                        "utf8mb4_bin")),
                .init(id: "moved-row", check: .init("SELECT id,n FROM otherdb.mt_moved", "1\tfirst")),
                .init(id: "updated-moved-row", check: .init("SELECT id,n FROM otherdb.mt_updated", "1\tchanged")),
                .init(id: "swapped-integer-table", check: .init("SELECT id,n FROM otherdb.mt_swap_moved", "2\t20")),
                .init(id: "swapped-text-table", check: .init("SELECT id,n FROM ddlcompat.mt_swap_u", "1\tchanged")),
                .init(id: "like-copy-row", check: .init("SELECT id,n FROM otherdb.mt_copy", "3\t30")),
                .init(id: "like-copy-empty", check: .init("SELECT COUNT(*) FROM otherdb.mt_empty_copy", "0")),
                .init(
                    id: "dropped-destination-tables",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='otherdb' AND TABLE_NAME IN ('moved','copy','absent')",
                        "0")),
                .init(
                    id: "old-and-temporary-names-absent",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','spare','mt_move','mt_update','mt_swap_t','mt_spare')",
                        "0")),
                .init(id: "reused-name-row", check: .init("SELECT id,n FROM ddlcompat.u", "4\t4.25")),
                .init(
                    id: "reused-name-definition",
                    check: .init(
                        "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='u' AND COLUMN_NAME='n'",
                        "decimal(10,2)")),
            ], databases: ["ddlcompat", "otherdb"],
            cleanup: [
                "DROP TABLE ddlcompat.mt_swap_u,otherdb.mt_moved,otherdb.mt_updated,otherdb.mt_swap_moved,otherdb.mt_copy,otherdb.mt_empty_copy"
            ]))
    static let crossSchemaRelationships = Case(
        "cross-schema-relationships", "Cross-schema relationship metadata, cascades and ordered DROP with restart",
        [
            .init("CREATE TABLE ddlcompat.parent(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE TABLE ddlcompat.child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid))",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid),FOREIGN KEY(pid) REFERENCES ddlcompat.parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.parent VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.child VALUES(1,1)", phaseEnd: "prepare-original-pair"),
            .init("RENAME TABLE ddlcompat.parent TO otherdb.parent", restartBefore: true, phaseEnd: "move-parent"),
            .init("RENAME TABLE ddlcompat.child TO otherdb.moved_child", restartBefore: true),
            .init(
                "UPDATE otherdb.parent SET n=20 WHERE id=1",
                sqlTransactional: "UPDATE otherdb.parent SET id=2 WHERE id=1", phaseEnd: "move-child-and-update-parent"),
            .init(
                "RENAME TABLE otherdb.parent TO ddlcompat.parent,otherdb.moved_child TO ddlcompat.child",
                restartBefore: true, phaseEnd: "return-parent-and-child"),
            .init("DROP TABLE ddlcompat.child,ddlcompat.parent", restartBefore: true),
            // Retain the cs_move endpoint for the final comparison.
            .init("CREATE TABLE ddlcompat.cs_move_parent(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE TABLE ddlcompat.cs_move_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid))",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.cs_move_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid),FOREIGN KEY(pid) REFERENCES ddlcompat.cs_move_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.cs_move_parent VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.cs_move_child VALUES(1,1)"),
            .init("RENAME TABLE ddlcompat.cs_move_parent TO otherdb.cs_move_parent"),
            .init("RENAME TABLE ddlcompat.cs_move_child TO otherdb.cs_move_child"),
            // Retain the cs_update endpoint for the final comparison.
            .init("CREATE TABLE ddlcompat.cs_update_parent(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE TABLE ddlcompat.cs_update_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid))",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.cs_update_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid),FOREIGN KEY(pid) REFERENCES ddlcompat.cs_update_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.cs_update_parent VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.cs_update_child VALUES(1,1)"),
            .init("RENAME TABLE ddlcompat.cs_update_parent TO otherdb.cs_update_parent"),
            .init("RENAME TABLE ddlcompat.cs_update_child TO otherdb.cs_update_child"),
            .init(
                "UPDATE otherdb.cs_update_parent SET n=20 WHERE id=1",
                sqlTransactional: "UPDATE otherdb.cs_update_parent SET id=2 WHERE id=1"),
            // Retain the cs_return endpoint for the final comparison.
            .init("CREATE TABLE ddlcompat.cs_return_parent(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE TABLE ddlcompat.cs_return_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid))",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.cs_return_child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid),FOREIGN KEY(pid) REFERENCES ddlcompat.cs_return_parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.cs_return_parent VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.cs_return_child VALUES(1,1)"),
            .init("RENAME TABLE ddlcompat.cs_return_parent TO otherdb.cs_return_parent"),
            .init("RENAME TABLE ddlcompat.cs_return_child TO otherdb.cs_return_child"),
            .init(
                "UPDATE otherdb.cs_return_parent SET n=20 WHERE id=1",
                sqlTransactional: "UPDATE otherdb.cs_return_parent SET id=2 WHERE id=1"),
            .init(
                "RENAME TABLE otherdb.cs_return_parent TO ddlcompat.cs_return_parent,otherdb.cs_return_child TO ddlcompat.cs_return_child",
                phaseEnd: "drop-original-and-retain-endpoints"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "moved-parent-and-child",
                    check: .init(
                        "SELECT p.id,p.n,c.id,c.pid FROM otherdb.cs_move_parent p JOIN otherdb.cs_move_child c ON p.id=c.pid",
                        "1\t10\t1\t1")),
                .init(
                    id: "cascade-after-move",
                    check: .init(
                        "SELECT p.id,p.n,c.id,c.pid FROM otherdb.cs_update_parent p JOIN otherdb.cs_update_child c ON p.id=c.pid",
                        "1\t20\t1\t1"),
                    transactionalCheck: .init(
                        "SELECT p.id,p.n,c.id,c.pid FROM otherdb.cs_update_parent p JOIN otherdb.cs_update_child c ON p.id=c.pid",
                        "2\t10\t1\t2")),
                .init(
                    id: "returned-parent-and-child",
                    check: .init(
                        "SELECT p.id,p.n,c.id,c.pid FROM ddlcompat.cs_return_parent p JOIN ddlcompat.cs_return_child c ON p.id=c.pid",
                        "1\t20\t1\t1"),
                    transactionalCheck: .init(
                        "SELECT p.id,p.n,c.id,c.pid FROM ddlcompat.cs_return_parent p JOIN ddlcompat.cs_return_child c ON p.id=c.pid",
                        "2\t10\t1\t2")),
                .init(
                    id: "dropped-original-tables",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE (TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('parent','child')) OR (TABLE_SCHEMA='otherdb' AND TABLE_NAME IN ('parent','moved_child','cs_return_parent','cs_return_child'))",
                        "0")),
                .init(
                    id: "moved-foreign-key",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='otherdb' AND TABLE_NAME='cs_move_child'",
                        "0"),
                    transactionalCheck: .init(
                        "SELECT REFERENCED_TABLE_NAME,UPDATE_RULE,DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='otherdb' AND TABLE_NAME='cs_move_child'",
                        "cs_move_parent\tCASCADE\tCASCADE")),
                .init(
                    id: "returned-foreign-key",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_return_child' AND REFERENCED_TABLE_NAME IS NOT NULL",
                        "0"),
                    transactionalCheck: .init(
                        "SELECT REFERENCED_TABLE_SCHEMA,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_return_child' AND REFERENCED_TABLE_NAME IS NOT NULL",
                        "ddlcompat\tcs_return_parent\tid")),
            ], databases: ["ddlcompat", "otherdb"],
            cleanup: [
                "DROP TABLE otherdb.cs_move_child,otherdb.cs_update_child,ddlcompat.cs_return_child,otherdb.cs_move_parent,otherdb.cs_update_parent,ddlcompat.cs_return_parent"
            ]))
}
