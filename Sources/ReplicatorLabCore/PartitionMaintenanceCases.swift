import Foundation

extension DDLCompatibilityCases {
    static let partitionKeyAlgorithm = Case(
        "partition-key-algorithm", "KEY algorithm 1 placement, schema discovery, ALTER, restart and offline replay",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"),
            .init(
                "INSERT INTO ddlcompat.t VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)",
                [
                    .init("SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.t PARTITION(p0)", "1,5,9,13")
                ]),
            .init(
                "ALTER TABLE ddlcompat.t TRUNCATE PARTITION p0",
                [.init("SELECT COUNT(*),SUM(n) FROM ddlcompat.t", "12\t1080")]),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION PARTITIONS 2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=2(id) PARTITIONS 4"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init(
                "INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t",
                [.init("SELECT COUNT(*),SUM(n) FROM ddlcompat.copy", "12\t1080")], restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.sub(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY KEY ALGORITHM=1(id) SUBPARTITIONS 4(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "INSERT INTO ddlcompat.sub VALUES(1,10),(2,20),(3,30),(4,40)",
                [.init("SELECT id FROM ddlcompat.sub PARTITION(psp0)", "1")]),
            .init(
                "ALTER TABLE ddlcompat.sub REORGANIZE PARTITION p INTO(PARTITION low VALUES LESS THAN(3),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "UPDATE ddlcompat.sub SET n=n+1",
                [
                    .init("SELECT id,n FROM ddlcompat.sub ORDER BY id", "1\t11\n2\t21\n3\t31\n4\t41"),
                    .init("SELECT id FROM ddlcompat.sub PARTITION(lowsp0)", "1"),
                ], restartBefore: true),
        ], nativeInnoDB: true)

    static let partitionMaintenance = Case(
        "partition-maintenance", "Logged partition administration, unlogged CHECK and LOCAL, following DML and restart",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.t ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.t OPTIMIZE PARTITION p"),
            .init("ALTER TABLE ddlcompat.t REPAIR PARTITION ALL", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t CHECK PARTITION ALL EXTENDED", transactions: 0),
            .init("ALTER TABLE ddlcompat.t ANALYZE PARTITION LOCAL ALL", transactions: 0),
            .init(
                "UPDATE ddlcompat.t SET n=n+1", [.init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")],
                restartBefore: true),
        ], nativeInnoDB: true)
}
