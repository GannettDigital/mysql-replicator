import Foundation

extension DDLCompatibilityCases {
    static let subpartitions = Case(
        "subpartitions",
        "Subpartition metadata, data-changing ALTER, CREATE LIKE, saved-state restart and offline replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init(
                "ALTER TABLE ddlcompat.t TRUNCATE PARTITION p0sp1",
                [.init("SELECT id FROM ddlcompat.t ORDER BY id", "2\n11\n12")]),
            .init("CREATE TABLE ddlcompat.stage(id INT PRIMARY KEY,n INT)", restartBefore: true),
            .init("INSERT INTO ddlcompat.stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.t EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.stage WITH VALIDATION",
                [
                    .init("SELECT id FROM ddlcompat.t ORDER BY id", "4\n11\n12"),
                    .init("SELECT id FROM ddlcompat.stage", "2"),
                ]),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(18,180)", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t DROP PARTITION p10", [.init("SELECT id FROM ddlcompat.t ORDER BY id", "4\n18")]
            ),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.t VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.t SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.t WHERE id=23"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init(
                "INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t",
                [.init("SELECT id,n FROM ddlcompat.copy ORDER BY id", "4\t40\n18\t180\n22\t220")]),
            .init("ALTER TABLE ddlcompat.copy REMOVE PARTITIONING"),
            .init(
                "ALTER TABLE ddlcompat.t PARTITION BY LIST COLUMNS(id) SUBPARTITION BY LINEAR KEY ALGORITHM=2(id) SUBPARTITIONS 2(PARTITION p4 VALUES IN(4),PARTITION p18 VALUES IN(18),PARTITION p22 VALUES IN(22))"
            ),
            .init(
                "UPDATE ddlcompat.t SET n=221 WHERE id=22",
                [
                    .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "4\t40\n18\t180\n22\t221"),
                    .init(
                        "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "p4sp0,p4sp1,p18sp0,p18sp1,p22sp0,p22sp1"),
                ], restartBefore: true),
        ], nativeInnoDB: true)

    static let partitionHashForms = Case(
        "partition-hash-forms", "Named HASH partitions, partition engine options, ADD count and implicit KEY columns",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init(
                "ALTER TABLE ddlcompat.t ADD PARTITION PARTITIONS 2",
                [
                    .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "early,late,p2,p3")
                ]),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION(PARTITION extra)"),
            .init(
                "UPDATE ddlcompat.t SET n=n+1", [.init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")],
                restartBefore: true),
        ], nativeInnoDB: true)
}
