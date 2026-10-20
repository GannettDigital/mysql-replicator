import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyControls = Case(
        "foreign-key-controls", "Self-references, cycles, source foreign_key_checks, restart and offline replay",
        [
            .init(
                "CREATE TABLE ddlcompat.tree(id INT PRIMARY KEY,pid INT,n INT,CONSTRAINT tree_fk FOREIGN KEY(pid) REFERENCES ddlcompat.tree(id) ON DELETE CASCADE ON UPDATE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.tree VALUES(1,NULL,10),(2,1,20),(3,2,30)"),
            .init("UPDATE ddlcompat.tree SET n=21 WHERE id=2", restartBefore: true),
            .init("DELETE FROM ddlcompat.tree WHERE id=1", [.init("SELECT COUNT(*) FROM ddlcompat.tree", "0")]),
            .init("CREATE TABLE ddlcompat.a(id INT PRIMARY KEY,bid INT) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.b(id INT PRIMARY KEY,aid INT,CONSTRAINT b_fk FOREIGN KEY(aid) REFERENCES ddlcompat.a(id) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init(
                "ALTER TABLE ddlcompat.a ADD CONSTRAINT a_fk FOREIGN KEY(bid) REFERENCES ddlcompat.b(id) ON DELETE CASCADE"
            ),
            .init(
                "BEGIN; INSERT INTO ddlcompat.a VALUES(1,NULL); INSERT INTO ddlcompat.b VALUES(2,1); UPDATE ddlcompat.a SET bid=2 WHERE id=1; COMMIT"
            ),
            .init(
                "DELETE FROM ddlcompat.a WHERE id=1", [.init("SELECT COUNT(*) FROM ddlcompat.b", "0")],
                restartBefore: true),
            .init("SET foreign_key_checks=0; INSERT INTO ddlcompat.b VALUES(3,999)"),
            .init("SET foreign_key_checks=0; UPDATE ddlcompat.b SET aid=998 WHERE id=3"),
            .init(
                "BEGIN; SET foreign_key_checks=0; INSERT INTO ddlcompat.b VALUES(4,997); SET foreign_key_checks=1; INSERT INTO ddlcompat.a VALUES(997,NULL); INSERT INTO ddlcompat.b VALUES(5,997); COMMIT"
            ),
            .init(
                "SET foreign_key_checks=0; DELETE FROM ddlcompat.a WHERE id=997",
                [.init("SELECT COUNT(*) FROM ddlcompat.b WHERE aid=997", "2")]),
            .init("INSERT INTO ddlcompat.a VALUES(997,NULL)", restartBefore: true),
            .init(
                "DELETE FROM ddlcompat.a WHERE id=997", [.init("SELECT COUNT(*) FROM ddlcompat.b WHERE aid=997", "0")]),
            .init("CREATE TABLE ddlcompat.loose(id INT PRIMARY KEY,pid INT) ENGINE=InnoDB"),
            .init("INSERT INTO ddlcompat.loose VALUES(1,999)"),
            .init(
                "SET foreign_key_checks=0; ALTER TABLE ddlcompat.loose ADD CONSTRAINT loose_fk FOREIGN KEY(pid) REFERENCES ddlcompat.a(id)"
            ),
            .init("UPDATE ddlcompat.loose SET pid=NULL WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.loose DROP FOREIGN KEY loose_fk"),
            .init("ALTER TABLE ddlcompat.a DROP FOREIGN KEY a_fk"),
            .init("ALTER TABLE ddlcompat.b DROP FOREIGN KEY b_fk"),
            .init("ALTER TABLE ddlcompat.tree DROP FOREIGN KEY tree_fk"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
