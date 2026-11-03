import Foundation

extension DDLCompatibilityCases {
    static let partitionKeyAlgorithm = Case(
        "partition-key-algorithm", "KEY partitioning: algorithms, partition placement and CREATE LIKE",
        [
            // Preserve the original source operations before independent retained histories.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"),
            .init(
                "INSERT INTO ddlcompat.t VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION p0", phaseEnd: "create-seed-and-truncate"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION PARTITIONS 2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=2(id) PARTITIONS 4"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t", phaseEnd: "resize-and-copy"),
            .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.sub(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY KEY ALGORITHM=1(id) SUBPARTITIONS 4(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.sub VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sub REORGANIZE PARTITION p INTO(PARTITION low VALUES LESS THAN(3),PARTITION high VALUES LESS THAN MAXVALUE)",
                phaseEnd: "fill-and-reorganize"),
            .init("UPDATE ddlcompat.sub SET n=n+1", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.ka_seed(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"
            ),
            .init(
                "INSERT INTO ddlcompat.ka_seed VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init(
                "CREATE TABLE ddlcompat.ka_truncated(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"
            ),
            .init(
                "INSERT INTO ddlcompat.ka_truncated VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init("ALTER TABLE ddlcompat.ka_truncated TRUNCATE PARTITION p0"),
            .init(
                "CREATE TABLE ddlcompat.ka_added(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"
            ),
            .init(
                "INSERT INTO ddlcompat.ka_added VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init("ALTER TABLE ddlcompat.ka_added TRUNCATE PARTITION p0"),
            .init("ALTER TABLE ddlcompat.ka_added ADD PARTITION PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.ka_coalesced(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"
            ),
            .init(
                "INSERT INTO ddlcompat.ka_coalesced VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init("ALTER TABLE ddlcompat.ka_coalesced TRUNCATE PARTITION p0"),
            .init("ALTER TABLE ddlcompat.ka_coalesced ADD PARTITION PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.ka_coalesced COALESCE PARTITION 2"),
            .init(
                "CREATE TABLE ddlcompat.ka_algorithm_two(id INT PRIMARY KEY,n INT) PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4"
            ),
            .init(
                "INSERT INTO ddlcompat.ka_algorithm_two VALUES(1,10),(2,20),(3,30),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90),(10,100),(11,110),(12,120),(13,130),(14,140),(15,150),(16,160)"
            ),
            .init("ALTER TABLE ddlcompat.ka_algorithm_two TRUNCATE PARTITION p0"),
            .init("ALTER TABLE ddlcompat.ka_algorithm_two ADD PARTITION PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.ka_algorithm_two COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.ka_algorithm_two PARTITION BY KEY ALGORITHM=2(id) PARTITIONS 4"),
            .init(
                "CREATE TABLE ddlcompat.ka_sub_seed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY KEY ALGORITHM=1(id) SUBPARTITIONS 4(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ka_sub_seed VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init(
                "CREATE TABLE ddlcompat.ka_sub_reorganized(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY KEY ALGORITHM=1(id) SUBPARTITIONS 4(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ka_sub_reorganized VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.ka_sub_reorganized REORGANIZE PARTITION p INTO(PARTITION low VALUES LESS THAN(3),PARTITION high VALUES LESS THAN MAXVALUE)",
                phaseEnd: "update-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "algorithm-one-placement",
                    check: .init("SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.ka_seed PARTITION(p0)", "1,5,9,13")
                ),
                .init(
                    id: "truncated-count-sum",
                    check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.ka_truncated", "12\t1080")),
                .init(id: "copied-count-sum", check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.copy", "12\t1080")),
                .init(
                    id: "initial-subpartition-placement",
                    check: .init("SELECT id FROM ddlcompat.ka_sub_seed PARTITION(psp0)", "1")),
                .init(
                    id: "updated-subpartition-rows",
                    check: .init("SELECT id,n FROM ddlcompat.sub ORDER BY id", "1\t11\n2\t21\n3\t31\n4\t41")),
                .init(
                    id: "reorganized-subpartition-placement",
                    check: .init("SELECT id FROM ddlcompat.sub PARTITION(lowsp0)", "1")),
                .init(
                    id: "truncated-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.ka_truncated PARTITION(p0)", "0")),
                .init(
                    id: "ka-added-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ka_added' GROUP BY PARTITION_METHOD",
                        "KEY\t6")),
                .init(
                    id: "ka-coalesced-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ka_coalesced' GROUP BY PARTITION_METHOD",
                        "KEY\t4")),
                .init(
                    id: "ka-algorithm-two-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ka_algorithm_two' GROUP BY PARTITION_METHOD",
                        "KEY\t4")),
                .init(
                    id: "ka-added-remaining-rows",
                    check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.ka_added", "12\t1080")),
                .init(
                    id: "ka-coalesced-remaining-rows",
                    check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.ka_coalesced", "12\t1080")),
                .init(
                    id: "ka-algorithm-two-remaining-rows",
                    check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.ka_algorithm_two", "12\t1080")),
                .init(id: "t-remaining-rows", check: .init("SELECT COUNT(*),SUM(n) FROM ddlcompat.t", "12\t1080")),
                .init(
                    id: "sub-before-update",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.ka_sub_reorganized ORDER BY id", "1\t10\n2\t20\n3\t30\n4\t40")),
                .init(
                    id: "sub-low-rows",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.ka_sub_reorganized PARTITION(low) ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "sub-high-rows",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.ka_sub_reorganized PARTITION(high) ORDER BY id", "3\t30\n4\t40")),
                .init(
                    id: "sub-reorganized-counts",
                    check: .init(
                        "SELECT PARTITION_NAME,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ka_sub_reorganized' GROUP BY PARTITION_ORDINAL_POSITION,PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION",
                        "low\t4\nhigh\t4")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ka_seed,ddlcompat.ka_truncated,ddlcompat.ka_added,ddlcompat.ka_coalesced,ddlcompat.ka_algorithm_two,ddlcompat.ka_sub_seed,ddlcompat.ka_sub_reorganized"
            ]
        ))

    static let partitionMaintenance = Case(
        "partition-maintenance", "Partition maintenance: logged operations, CHECK and LOCAL",
        [
            // Preserve the original source operations before independent retained histories.
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.t ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.t OPTIMIZE PARTITION p", phaseEnd: "create-seed-and-maintain"),
            .init("ALTER TABLE ddlcompat.t REPAIR PARTITION ALL", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t CHECK PARTITION ALL EXTENDED", transactions: 0),
            .init(
                "ALTER TABLE ddlcompat.t ANALYZE PARTITION LOCAL ALL", transactions: 0,
                phaseEnd: "repair-check-and-local"),
            .init("UPDATE ddlcompat.t SET n=n+1", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.pm_seed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_seed VALUES(1,10),(2,20)"),
            .init(
                "CREATE TABLE ddlcompat.pm_rebuilt(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_rebuilt VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_rebuilt REBUILD PARTITION ALL"),
            .init(
                "CREATE TABLE ddlcompat.pm_analyzed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_analyzed VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_analyzed REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_analyzed ANALYZE PARTITION psp0"),
            .init(
                "CREATE TABLE ddlcompat.pm_optimized(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_optimized VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_optimized REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_optimized ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.pm_optimized OPTIMIZE PARTITION p"),
            .init(
                "CREATE TABLE ddlcompat.pm_repaired(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_repaired VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_repaired REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_repaired ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.pm_repaired OPTIMIZE PARTITION p"),
            .init("ALTER TABLE ddlcompat.pm_repaired REPAIR PARTITION ALL"),
            .init(
                "CREATE TABLE ddlcompat.pm_checked(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_checked VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_checked REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_checked ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.pm_checked OPTIMIZE PARTITION p"),
            .init("ALTER TABLE ddlcompat.pm_checked REPAIR PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_checked CHECK PARTITION ALL EXTENDED", transactions: 0),
            .init(
                "CREATE TABLE ddlcompat.pm_local(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pm_local VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pm_local REBUILD PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_local ANALYZE PARTITION psp0"),
            .init("ALTER TABLE ddlcompat.pm_local OPTIMIZE PARTITION p"),
            .init("ALTER TABLE ddlcompat.pm_local REPAIR PARTITION ALL"),
            .init("ALTER TABLE ddlcompat.pm_local CHECK PARTITION ALL EXTENDED", transactions: 0),
            .init(
                "ALTER TABLE ddlcompat.pm_local ANALYZE PARTITION LOCAL ALL", transactions: 0,
                phaseEnd: "update-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(id: "updated-rows", check: .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")),
                .init(
                    id: "pm-seed-rows", check: .init("SELECT id,n FROM ddlcompat.pm_seed ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-rebuilt-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pm_rebuilt ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-analyzed-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pm_analyzed ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-optimized-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pm_optimized ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-repaired-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pm_repaired ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-checked-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pm_checked ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "pm-local-rows", check: .init("SELECT id,n FROM ddlcompat.pm_local ORDER BY id", "1\t10\n2\t20")
                ),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.pm_seed,ddlcompat.pm_rebuilt,ddlcompat.pm_analyzed,ddlcompat.pm_optimized,ddlcompat.pm_repaired,ddlcompat.pm_checked,ddlcompat.pm_local"
            ]
        ))

}
