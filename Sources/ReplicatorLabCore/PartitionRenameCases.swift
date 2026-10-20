import Foundation

extension DDLCompatibilityCases {
    static let partitionColumnRenames = Case(
        "partition-column-renames",
        "Column and subpartition renames with replacement/removal, implicit KEY, DML, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
                [.init("SELECT x,y,n FROM ddlcompat.t ORDER BY x", "1\t10\t100\n11\t20\t200")], restartBefore: true),
            .init(
                "UPDATE ddlcompat.t SET x=21,y=30,n=101 WHERE x=1 AND y=10",
                [.init("SELECT x,y,n FROM ddlcompat.t PARTITION(p1) ORDER BY x", "11\t20\t200\n21\t30\t101")]),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
                [.init("SELECT y,x,n FROM ddlcompat.t ORDER BY y", "11\t20\t200\n21\t30\t101")], restartBefore: true),
            .init(
                "INSERT INTO ddlcompat.t(y,x,n) VALUES(2,3,4)",
                [.init("SELECT y,x,n FROM ddlcompat.t PARTITION(p0)", "2\t3\t4")]),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING",
                [
                    .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND PARTITION_NAME IS NOT NULL",
                        "0")
                ], restartBefore: true),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE id key_id INT",
                [.init("SELECT key_id,sid,n FROM ddlcompat.t ORDER BY key_id", "2\t3\t4\n11\t20\t200\n21\t30\t101")],
                restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=201 WHERE key_id=11 AND sid=20"),
            .init("ALTER TABLE ddlcompat.t CHANGE key_id final_id INT REMOVE PARTITIONING"),
            .init(
                "DELETE FROM ddlcompat.t WHERE final_id=2 AND sid=3",
                [.init("SELECT final_id,sid,n FROM ddlcompat.t ORDER BY final_id", "11\t20\t201\n21\t30\t101")]),
            .init("DROP TABLE ddlcompat.t"),
        ], nativeInnoDB: true)

    static let partitionRenameSyntax = Case(
        "partition-rename-syntax", "RENAME COLUMN translation with replacement and removal of partitioning",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(11,20)"),
            .init(
                "ALTER TABLE ddlcompat.t RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)",
                [.init("SELECT renamed,n FROM ddlcompat.t ORDER BY renamed", "1\t10\n11\t20")], restartBefore: true),
            .init(
                "UPDATE ddlcompat.t SET renamed=21 WHERE renamed=1",
                [.init("SELECT renamed,n FROM ddlcompat.t PARTITION(high) ORDER BY renamed", "11\t20\n21\t10")]),
            .init("ALTER TABLE ddlcompat.t RENAME COLUMN renamed TO id REMOVE PARTITIONING", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=11", [.init("SELECT id,n FROM ddlcompat.t", "21\t10")]),
            .init("DROP TABLE ddlcompat.t"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .reverse: "MySQL 5.7 has no RENAME COLUMN syntax.",
            .mysql57MyISAM: "MySQL 5.7 has no RENAME COLUMN syntax.",
            .mysql57InnoDB: "MySQL 5.7 has no RENAME COLUMN syntax.",
        ])
}
