import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyGenerated = Case(
        "foreign-key-generated", "Stored generated FK columns, native action limits, cascades, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.p(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,UNIQUE KEY(v)) ENGINE=InnoDB"),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,b INT,pid INT AS (b+1) STORED,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(v) ON DELETE CASCADE) ENGINE=InnoDB"
            ),
            .init(
                "CREATE TABLE ddlcompat.n(id INT PRIMARY KEY,pid INT,CONSTRAINT nf FOREIGN KEY(pid) REFERENCES ddlcompat.p(v) ON UPDATE CASCADE ON DELETE SET NULL) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p(id,b) VALUES(1,10),(2,20)"),
            .init("INSERT INTO ddlcompat.c(id,b) VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.n VALUES(1,21)"),
            .init(
                "UPDATE ddlcompat.p SET b=21 WHERE id=2", [.init("SELECT pid FROM ddlcompat.n", "22")],
                restartBefore: true),
            .init("UPDATE ddlcompat.c SET b=21 WHERE id=1", [.init("SELECT pid FROM ddlcompat.c", "22")]),
            .init(
                "DELETE FROM ddlcompat.p WHERE id=2",
                [.init("SELECT COUNT(*) FROM ddlcompat.c", "0"), .init("SELECT pid FROM ddlcompat.n", "NULL")]),
            .init("ALTER TABLE ddlcompat.c DROP FOREIGN KEY cf"),
            .init(
                "ALTER TABLE ddlcompat.c ADD CONSTRAINT cf2 FOREIGN KEY(pid) REFERENCES ddlcompat.p(v) ON DELETE CASCADE"
            ),
            .init("INSERT INTO ddlcompat.c(id,b) VALUES(2,10)", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.virtual_base(id INT PRIMARY KEY,pid INT,g INT AS (pid+1) VIRTUAL,KEY(g),CONSTRAINT vf FOREIGN KEY(pid) REFERENCES ddlcompat.p(v) ON UPDATE CASCADE ON DELETE SET NULL) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.virtual_base(id,pid) VALUES(1,11)"),
            .init("DELETE FROM ddlcompat.c"),
            .init(
                "UPDATE ddlcompat.p SET b=12 WHERE id=1", [.init("SELECT pid,g FROM ddlcompat.virtual_base", "13\t14")]),
            .init(
                "DELETE FROM ddlcompat.p WHERE id=1", [.init("SELECT pid,g FROM ddlcompat.virtual_base", "NULL\tNULL")],
                restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.stored_base(id INT PRIMARY KEY,pid INT,g INT AS (pid+1) STORED,CONSTRAINT bf FOREIGN KEY(pid) REFERENCES ddlcompat.p(v)) ENGINE=InnoDB"
            ),
            .init("INSERT INTO ddlcompat.p(id,b) VALUES(3,30)"),
            .init(
                "INSERT INTO ddlcompat.stored_base(id,pid) VALUES(1,31)",
                [.init("SELECT g FROM ddlcompat.stored_base", "32")]),
            .init(
                "CREATE TABLE ddlcompat.vparent(id INT PRIMARY KEY,b INT,v INT AS (b+1) VIRTUAL,UNIQUE KEY(v)) ENGINE=InnoDB"
            ),
        ], nativeInnoDB: true,
        profileExclusions: [
            .forward: "Foreign keys require an InnoDB target.",
            .mysql57MyISAM: "Foreign keys require an InnoDB target.",
        ])

    static let foreignKeyGeneratedRejections: [(String, [String])] = [
        (
            "CREATE TABLE ddlcompat.bad(id INT PRIMARY KEY,b INT,v INT AS (b+1) VIRTUAL,FOREIGN KEY(v) REFERENCES ddlcompat.p(v)) ENGINE=InnoDB",
            ["1215", "3733"]
        ),
        (
            "CREATE TABLE ddlcompat.bad(id INT PRIMARY KEY,v INT,FOREIGN KEY(v) REFERENCES ddlcompat.vparent(v)) ENGINE=InnoDB",
            ["1215", "3733"]
        ),
        (
            "CREATE TABLE ddlcompat.bad(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,FOREIGN KEY(v) REFERENCES ddlcompat.p(v) ON UPDATE CASCADE) ENGINE=InnoDB",
            ["3104"]
        ),
        (
            "CREATE TABLE ddlcompat.bad(id INT PRIMARY KEY,b INT,v INT AS (b+1) STORED,FOREIGN KEY(v) REFERENCES ddlcompat.p(v) ON DELETE SET NULL) ENGINE=InnoDB",
            ["3104"]
        ),
        (
            "CREATE TABLE ddlcompat.bad(id INT PRIMARY KEY,v INT,g INT AS (v+1) STORED,FOREIGN KEY(v) REFERENCES ddlcompat.p(v) ON DELETE CASCADE) ENGINE=InnoDB",
            ["1215"]
        ),
    ]
}
