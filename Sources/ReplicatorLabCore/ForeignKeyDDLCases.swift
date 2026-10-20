import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyDDL = Case(
        "foreign-key-ddl", "FK supporting indexes, column renames, internal database DROP, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,pid INT,n INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(id) ON UPDATE CASCADE ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init(
                "CREATE TABLE ddlcompat.e(id INT PRIMARY KEY,pid INT,n INT,KEY explicit_pid(pid),CONSTRAINT ef FOREIGN KEY(pid) REFERENCES ddlcompat.p(id) ON UPDATE CASCADE ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init(
                "BEGIN; INSERT INTO ddlcompat.p VALUES(1),(2); INSERT INTO ddlcompat.c VALUES(1,1,10),(2,2,20); INSERT INTO ddlcompat.e VALUES(1,1,10),(2,2,20); COMMIT"
            ),
            .init(
                "ALTER TABLE ddlcompat.c ADD KEY wide(pid,n),ALTER COLUMN n SET DEFAULT 7",
                [
                    .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND INDEX_NAME='cf'",
                        "0")
                ]),
            .init(
                "CREATE INDEX wide ON ddlcompat.e(pid,n)",
                [
                    .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='e' AND INDEX_NAME='explicit_pid'",
                        "1")
                ]),
            .init("ALTER TABLE ddlcompat.c CHANGE pid parent_id INT", restartBefore: true),
            .init("ALTER TABLE ddlcompat.p CHANGE id parent_key INT NOT NULL"),
            .init(
                "UPDATE ddlcompat.p SET parent_key=11 WHERE parent_key=1",
                [
                    .init("SELECT parent_id FROM ddlcompat.c WHERE id=1", "11"),
                    .init("SELECT pid FROM ddlcompat.e WHERE id=1", "11"),
                ], restartBefore: true),
            .init("DROP INDEX explicit_pid ON ddlcompat.e"),
            .init("ALTER TABLE ddlcompat.c RENAME INDEX wide TO renamed"),
            .init(
                "ALTER TABLE ddlcompat.c ADD KEY wider(parent_id,n,id)",
                [
                    .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND INDEX_NAME='renamed'",
                        "2")
                ]),
            .init(
                "DELETE FROM ddlcompat.p WHERE parent_key=11",
                [.init("SELECT COUNT(*) FROM ddlcompat.c", "1"), .init("SELECT COUNT(*) FROM ddlcompat.e", "1")]),
            .init(
                "CREATE TABLE ddlcompat.tree(id INT PRIMARY KEY,pid INT,CONSTRAINT tf FOREIGN KEY(pid) REFERENCES ddlcompat.tree(id) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.tree VALUES(1,NULL),(2,1)"),
            .init("ALTER TABLE ddlcompat.tree CHANGE id node_id INT NOT NULL, CHANGE pid parent_id INT"),
            .init(
                "DELETE FROM ddlcompat.tree WHERE node_id=1", [.init("SELECT COUNT(*) FROM ddlcompat.tree", "0")],
                restartBefore: true),
            .init("DROP DATABASE ddlcompat", restartBefore: true),
            .init("CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init("INSERT INTO ddlcompat.t VALUES(99)"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
