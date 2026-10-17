import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyParentKeys = Case(
        "foreign-key-parent-keys", "Native nonunique, composite-prefix and extended parent keys, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY,n INT,KEY by_n(n)) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(n) ON DELETE CASCADE ON UPDATE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p VALUES(1,7),(2,7)"),
            .init("INSERT INTO ddlcompat.c VALUES(1,7)"),
            .init(
                "DELETE FROM ddlcompat.p WHERE id=1",
                [.init("SELECT COUNT(*) FROM ddlcompat.p", "1"), .init("SELECT COUNT(*) FROM ddlcompat.c", "0")]),
            .init("ALTER TABLE ddlcompat.p ADD KEY wider(n,id),DROP INDEX by_n"),
            .init("INSERT INTO ddlcompat.c VALUES(2,7)", restartBefore: true),
            .init("UPDATE ddlcompat.p SET n=8 WHERE id=2", [.init("SELECT pid FROM ddlcompat.c WHERE id=2", "8")]),
            .init("DELETE FROM ddlcompat.p WHERE id=2", [.init("SELECT COUNT(*) FROM ddlcompat.c", "0")]),
            .init("CREATE TABLE ddlcompat.p2(a INT,b INT,PRIMARY KEY(a,b)) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c2(id INT PRIMARY KEY,pid INT,CONSTRAINT cf2 FOREIGN KEY(pid) REFERENCES ddlcompat.p2(a) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p2 VALUES(9,1),(9,2)"),
            .init("INSERT INTO ddlcompat.c2 VALUES(1,9)"),
            .init(
                "DELETE FROM ddlcompat.p2 WHERE b=1", [.init("SELECT COUNT(*) FROM ddlcompat.c2", "0")],
                restartBefore: true),
            .init("CREATE TABLE ddlcompat.p3(id INT PRIMARY KEY,n INT,KEY by_n(n)) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c3(id INT PRIMARY KEY,n INT,pid INT,CONSTRAINT cf3 FOREIGN KEY(n,pid) REFERENCES ddlcompat.p3(n,id) ON DELETE CASCADE ON UPDATE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p3 VALUES(3,33)"),
            .init("INSERT INTO ddlcompat.c3 VALUES(1,33,3)"),
            .init("UPDATE ddlcompat.p3 SET n=34 WHERE id=3", [.init("SELECT n FROM ddlcompat.c3", "34")]),
            .init("CREATE TABLE ddlcompat.p4(id INT NOT NULL,n INT,UNIQUE KEY uk(id),KEY by_n(n)) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c4(id INT PRIMARY KEY,n INT,pid INT,CONSTRAINT cf4 FOREIGN KEY(n,pid) REFERENCES ddlcompat.p4(n,id) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p4 VALUES(4,44)"),
            .init("INSERT INTO ddlcompat.c4 VALUES(1,44,4)"),
            .init(
                "DELETE FROM ddlcompat.p4 WHERE id=4", [.init("SELECT COUNT(*) FROM ddlcompat.c4", "0")],
                restartBefore: true),
            .init("CREATE TABLE ddlcompat.c5(id INT PRIMARY KEY,pid INT) ENGINE=InnoDB"),
            .init(
                "ALTER TABLE ddlcompat.c5 ADD CONSTRAINT cf5 FOREIGN KEY(pid) REFERENCES ddlcompat.p(n) ON DELETE CASCADE"
            ),
            .init("INSERT INTO ddlcompat.p VALUES(5,55)"),
            .init("INSERT INTO ddlcompat.c5 VALUES(1,55)"),
            .init("DELETE FROM ddlcompat.p WHERE id=5", [.init("SELECT COUNT(*) FROM ddlcompat.c5", "0")]),
            .init(
                "DROP TABLE ddlcompat.c,ddlcompat.c2,ddlcompat.c3,ddlcompat.c4,ddlcompat.c5,ddlcompat.p,ddlcompat.p2,ddlcompat.p3,ddlcompat.p4"
            ),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])
}
