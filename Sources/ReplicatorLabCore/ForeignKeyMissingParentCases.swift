import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyMissingParent = Case(
        "foreign-key-missing-parent", "Missing FK parents, disabled checks, parent recreation, restart and replay",
        [
            .init(
                "SET foreign_key_checks=0; CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,pid INT,n INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(id) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init("SET foreign_key_checks=0; INSERT INTO ddlcompat.c VALUES(1,999,10),(2,NULL,20)"),
            .init("UPDATE ddlcompat.c SET n=11 WHERE id=1", restartBefore: true),
            .init("DELETE FROM ddlcompat.c WHERE id=2"),
            .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init("INSERT INTO ddlcompat.p VALUES(999)"),
            .init(
                "DELETE FROM ddlcompat.p WHERE id=999", [.init("SELECT COUNT(*) FROM ddlcompat.c", "0")],
                restartBefore: true),
            .init("SET foreign_key_checks=0; DROP TABLE ddlcompat.p"),
            .init("SET foreign_key_checks=0; INSERT INTO ddlcompat.c VALUES(3,7,30)", restartBefore: true),
            .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init("INSERT INTO ddlcompat.p VALUES(7)"),
            .init("DELETE FROM ddlcompat.p WHERE id=7", [.init("SELECT COUNT(*) FROM ddlcompat.c", "0")]),
            .init("ALTER TABLE ddlcompat.c DROP FOREIGN KEY cf"),
            .init(
                "SET foreign_key_checks=0; ALTER TABLE ddlcompat.c ADD CONSTRAINT cf2 FOREIGN KEY(pid) REFERENCES ddlcompat.q(id) ON DELETE CASCADE"
            ),
            .init("INSERT INTO ddlcompat.c VALUES(4,NULL,40)", restartBefore: true),
            .init("CREATE TABLE ddlcompat.q(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init("INSERT INTO ddlcompat.q VALUES(8)"),
            .init("UPDATE ddlcompat.c SET pid=8 WHERE id=4"),
            .init("DELETE FROM ddlcompat.q WHERE id=8", [.init("SELECT COUNT(*) FROM ddlcompat.c", "0")]),
            .init("SET foreign_key_checks=0; DROP TABLE ddlcompat.q"),
            .init("DROP DATABASE ddlcompat", restartBefore: true),
            .init("CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY) ENGINE=InnoDB"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
