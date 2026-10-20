import Foundation

extension DDLCompatibilityCases {
    static let foreignKeySyntaxColumns = Case(
        "foreign-key-syntax-columns",
        "FK names, MySQL 5.7 MATCH actions and compatible column storage, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.p(id INT PRIMARY KEY,v VARCHAR(10),b VARBINARY(10),KEY(v),KEY(b)) ENGINE=InnoDB"
            ),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,pid INT,FOREIGN KEY named_index(pid) REFERENCES ddlcompat.p(id) MATCH FULL ON DELETE CASCADE ON UPDATE SET NULL) ENGINE=InnoDB",
                [
                    .init(
                        "SELECT CONSTRAINT_NAME,IF(DELETE_RULE IN ('RESTRICT','NO ACTION'),'restrict',DELETE_RULE),IF(UPDATE_RULE IN ('RESTRICT','NO ACTION'),'restrict',UPDATE_RULE) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='ddlcompat' AND TABLE_NAME='c'",
                        "c_ibfk_1\trestrict\trestrict"),
                    .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND INDEX_NAME!='PRIMARY'",
                        "named_index"),
                ]),
            .init("INSERT INTO ddlcompat.p VALUES(1,'value',X'0102')"),
            .init("INSERT INTO ddlcompat.c VALUES(1,1)"),
            .init("DELETE FROM ddlcompat.c WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.c DROP FOREIGN KEY c_ibfk_1"),
            .init(
                "ALTER TABLE ddlcompat.c ADD CONSTRAINT named_fk FOREIGN KEY other_index(pid) REFERENCES ddlcompat.p(id) MATCH SIMPLE ON DELETE SET DEFAULT",
                [
                    .init(
                        "SELECT CONSTRAINT_NAME,IF(DELETE_RULE IN ('RESTRICT','NO ACTION'),'restrict',DELETE_RULE) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='ddlcompat' AND TABLE_NAME='c'",
                        "named_fk\trestrict")
                ]),
            .init("INSERT INTO ddlcompat.c VALUES(2,1)"),
            .init(
                "CREATE TABLE ddlcompat.s(id INT PRIMARY KEY,v VARCHAR(20),b VARBINARY(20),CONSTRAINT sf FOREIGN KEY sv(v) REFERENCES ddlcompat.p(v) ON DELETE CASCADE ON UPDATE CASCADE,CONSTRAINT bf FOREIGN KEY(b) REFERENCES ddlcompat.p(b) ON DELETE CASCADE ON UPDATE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.s VALUES(1,'value',X'0102')"),
            .init(
                "UPDATE ddlcompat.p SET v='changed' WHERE id=1",
                [.init("SELECT v,HEX(b) FROM ddlcompat.s", "changed\t0102")], restartBefore: true),
            .init("DELETE FROM ddlcompat.c"),
            .init("DELETE FROM ddlcompat.p WHERE id=1", [.init("SELECT COUNT(*) FROM ddlcompat.s", "0")]),
            .init(
                "CREATE TABLE ddlcompat.types_p(id INT PRIMARY KEY,d DECIMAL(10,2),e ENUM('a','b'),y YEAR,t TIME(2),KEY(d),KEY(e),KEY(y),KEY(t)) ENGINE=InnoDB"
            ),
            .init(
                "CREATE TABLE ddlcompat.types_c(id INT PRIMARY KEY,d DECIMAL(12,3) UNSIGNED,e ENUM('c','d','e'),y TINYINT UNSIGNED,t DATETIME(6),FOREIGN KEY(d) REFERENCES ddlcompat.types_p(d),FOREIGN KEY(e) REFERENCES ddlcompat.types_p(e),FOREIGN KEY(y) REFERENCES ddlcompat.types_p(y),FOREIGN KEY(t) REFERENCES ddlcompat.types_p(t)) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.types_p VALUES(1,NULL,'a',NULL,NULL)"),
            .init(
                "INSERT INTO ddlcompat.types_c VALUES(1,NULL,'c',NULL,NULL)",
                [.init("SELECT id,e FROM ddlcompat.types_c", "1\tc")], restartBefore: true),
            .init("DROP TABLE ddlcompat.types_c,ddlcompat.types_p,ddlcompat.s,ddlcompat.c,ddlcompat.p"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
