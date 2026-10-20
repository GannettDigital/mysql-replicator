import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyCompoundIndexes = Case(
        "foreign-key-compound-indexes", "Compound FK/index/column changes, exact index choices, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,a INT,b INT,CONSTRAINT olda FOREIGN KEY(a) REFERENCES ddlcompat.p(id),CONSTRAINT oldb FOREIGN KEY(b) REFERENCES ddlcompat.p(id)) ENGINE=InnoDB"
            ),
            .init("ALTER TABLE ddlcompat.c DROP FOREIGN KEY olda,DROP FOREIGN KEY oldb"),
            .init(
                "ALTER TABLE ddlcompat.c ADD CONSTRAINT fa FOREIGN KEY(a) REFERENCES ddlcompat.p(id),ADD CONSTRAINT fb FOREIGN KEY(b) REFERENCES ddlcompat.p(id),ADD note INT DEFAULT 7"
            ),
            .init("INSERT INTO ddlcompat.p VALUES(1),(2)"),
            .init(
                "INSERT INTO ddlcompat.c(id,a,b) VALUES(10,1,2)", [.init("SELECT note FROM ddlcompat.c", "7")],
                restartBefore: true),
            .init("ALTER TABLE ddlcompat.c DROP FOREIGN KEY fa,DROP FOREIGN KEY fb,ADD KEY wide(a,b)"),
            .init(
                "ALTER TABLE ddlcompat.c ADD CONSTRAINT fa3 FOREIGN KEY(a) REFERENCES ddlcompat.p(id) ON DELETE CASCADE,ADD CONSTRAINT fb3 FOREIGN KEY(b) REFERENCES ddlcompat.p(id) ON UPDATE CASCADE"
            ),
            .init(
                "ALTER TABLE ddlcompat.c MODIFY note BIGINT DEFAULT 8,DROP FOREIGN KEY fb3,ADD CONSTRAINT fb4 FOREIGN KEY(b) REFERENCES ddlcompat.p(id) ON UPDATE CASCADE"
            ),
            .init(
                "UPDATE ddlcompat.p SET id=3 WHERE id=2", [.init("SELECT a,b,note FROM ddlcompat.c", "1\t3\t7")],
                restartBefore: true),
            .init("DELETE FROM ddlcompat.p WHERE id=1", [.init("SELECT COUNT(*) FROM ddlcompat.c", "0")]),
            .init(
                "ALTER TABLE ddlcompat.c RENAME INDEX fb4 TO kept,DROP FOREIGN KEY fb4,ADD CONSTRAINT fb5 FOREIGN KEY(b) REFERENCES ddlcompat.p(id)",
                [
                    .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND INDEX_NAME='kept'",
                        "1")
                ]),
            .init("CREATE TABLE ddlcompat.n(id INT PRIMARY KEY,a INT) ENGINE=InnoDB"),
            .init(
                "ALTER TABLE ddlcompat.n ADD CONSTRAINT fn1 FOREIGN KEY(a) REFERENCES ddlcompat.p(id),ADD CONSTRAINT fn2 FOREIGN KEY(a) REFERENCES ddlcompat.p(id)",
                [
                    .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='n' AND INDEX_NAME!='PRIMARY'",
                        "fn2")
                ]),
            .init("INSERT INTO ddlcompat.n VALUES(1,3)", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.e(id INT PRIMARY KEY,a INT,b INT,KEY explicit_a(a),KEY explicit_b(b)) ENGINE=InnoDB"
            ),
            .init(
                "ALTER TABLE ddlcompat.e ADD CONSTRAINT ef1 FOREIGN KEY(a) REFERENCES ddlcompat.p(id),ADD CONSTRAINT ef2 FOREIGN KEY(b) REFERENCES ddlcompat.p(id),ADD note INT DEFAULT 9",
                [
                    .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='e' AND INDEX_NAME!='PRIMARY' ORDER BY INDEX_NAME",
                        "explicit_a\nexplicit_b")
                ]),
            .init(
                "ALTER TABLE ddlcompat.e ADD CONSTRAINT ef3 FOREIGN KEY(a) REFERENCES ddlcompat.p(id),DROP FOREIGN KEY ef1,DROP INDEX explicit_a"
            ),
            .init("ALTER TABLE ddlcompat.e ADD CONSTRAINT ef4 FOREIGN KEY(d) REFERENCES ddlcompat.p(id),ADD d INT"),
            .init("INSERT INTO ddlcompat.e(id,a,b) VALUES(1,3,3)", [.init("SELECT note FROM ddlcompat.e", "9")]),
            .init("UPDATE ddlcompat.e SET d=3 WHERE id=1", [.init("SELECT d FROM ddlcompat.e", "3")]),
            .init(
                "CREATE TABLE ddlcompat.w(id INT PRIMARY KEY,a INT,b INT,CONSTRAINT wf FOREIGN KEY(a) REFERENCES ddlcompat.p(id)) ENGINE=InnoDB"
            ),
            .init("ALTER TABLE ddlcompat.w DROP FOREIGN KEY wf"),
            .init(
                "ALTER TABLE ddlcompat.w ADD KEY wider(a,b),ADD CONSTRAINT wf2 FOREIGN KEY(a) REFERENCES ddlcompat.p(id)",
                [
                    .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='w' AND INDEX_NAME!='PRIMARY' ORDER BY SEQ_IN_INDEX",
                        "wider\nwider")
                ]),
            .init("INSERT INTO ddlcompat.w VALUES(1,3,4)", restartBefore: true),
            .init("DROP TABLE ddlcompat.c,ddlcompat.n,ddlcompat.e,ddlcompat.w,ddlcompat.p"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
