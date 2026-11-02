import Foundation

extension DDLCompatibilityCases {
    static let subpartitions = Case(
        "subpartitions", "Subpartitioning: TRUNCATE, EXCHANGE, REORGANIZE and CREATE LIKE",
        [
            // Keep the original operations first, including each restart boundary.
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION p0sp1", phaseEnd: "truncate-subpartition"),
            .init("CREATE TABLE ddlcompat.stage(id INT PRIMARY KEY,n INT)", restartBefore: true),
            .init("INSERT INTO ddlcompat.stage VALUES(4,40)"),
            .init("ALTER TABLE ddlcompat.t EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.stage WITH VALIDATION"),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))",
                phaseEnd: "exchange-and-reorganize"),
            .init("INSERT INTO ddlcompat.t VALUES(18,180)", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.t VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.t SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.t WHERE id=23"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t"),
            .init("ALTER TABLE ddlcompat.copy REMOVE PARTITIONING"),
            .init(
                "ALTER TABLE ddlcompat.t PARTITION BY LIST COLUMNS(id) SUBPARTITION BY LINEAR KEY ALGORITHM=2(id) SUBPARTITIONS 2(PARTITION p4 VALUES IN(4),PARTITION p18 VALUES IN(18),PARTITION p22 VALUES IN(22))",
                phaseEnd: "change-and-copy-partitions"),
            .init("UPDATE ddlcompat.t SET n=221 WHERE id=22", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.sp_seed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_seed VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init(
                "CREATE TABLE ddlcompat.sp_truncated(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_truncated VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_truncated TRUNCATE PARTITION p0sp1"),
            .init(
                "CREATE TABLE ddlcompat.sp_stage_empty(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_stage_empty VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_stage_empty TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_stage_empty_stage(id INT PRIMARY KEY,n INT)"),
            .init(
                "CREATE TABLE ddlcompat.sp_stage_seeded(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_stage_seeded VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_stage_seeded TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_stage_seeded_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_stage_seeded_stage VALUES(4,40)"),
            .init(
                "CREATE TABLE ddlcompat.sp_exchanged(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_exchanged VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_exchanged TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_exchanged_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_exchanged_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_exchanged EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_exchanged_stage WITH VALIDATION"
            ),
            .init(
                "CREATE TABLE ddlcompat.sp_reorganized(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_reorganized VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_reorganized TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_reorganized_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_reorganized_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_reorganized EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_reorganized_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_reorganized REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init(
                "CREATE TABLE ddlcompat.sp_inserted(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_inserted VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_inserted TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_inserted_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_inserted_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_inserted EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_inserted_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_inserted REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_inserted VALUES(18,180)"),
            .init(
                "CREATE TABLE ddlcompat.sp_dropped(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_dropped VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_dropped TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_dropped_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_dropped_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_dropped EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_dropped_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_dropped REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_dropped VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_dropped DROP PARTITION p10"),
            .init(
                "CREATE TABLE ddlcompat.sp_added(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_added VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_added TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_added_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_added_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_added EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_added_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_added REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_added VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_added DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_added ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init(
                "CREATE TABLE ddlcompat.sp_seeded_new(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_seeded_new VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_seeded_new TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_seeded_new_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_seeded_new_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_seeded_new EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_seeded_new_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_seeded_new REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_seeded_new VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_seeded_new DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_seeded_new ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_seeded_new VALUES(22,22),(23,23)"),
            .init(
                "CREATE TABLE ddlcompat.sp_updated(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_updated VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_updated TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_updated_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_updated_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_updated EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_updated_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_updated REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_updated VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_updated DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_updated ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_updated VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_updated SET n=220 WHERE id=22"),
            .init(
                "CREATE TABLE ddlcompat.sp_deleted(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_deleted VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_deleted TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_deleted_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_deleted_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_deleted EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_deleted_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_deleted REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_deleted VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_deleted DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_deleted ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_deleted VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_deleted SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.sp_deleted WHERE id=23"),
            .init(
                "CREATE TABLE ddlcompat.sp_copy_empty(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_empty VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_copy_empty TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_copy_empty_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_copy_empty_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_empty EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_copy_empty_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_empty REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_empty VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_copy_empty DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_copy_empty ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_copy_empty VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_copy_empty SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.sp_copy_empty WHERE id=23"),
            .init("CREATE TABLE ddlcompat.sp_copy_empty_copy LIKE ddlcompat.sp_copy_empty"),
            .init(
                "CREATE TABLE ddlcompat.sp_copy_seeded(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_seeded VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_copy_seeded TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_copy_seeded_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_copy_seeded_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_seeded EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_copy_seeded_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_seeded REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_seeded VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_copy_seeded DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_copy_seeded ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_copy_seeded VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_copy_seeded SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.sp_copy_seeded WHERE id=23"),
            .init("CREATE TABLE ddlcompat.sp_copy_seeded_copy LIKE ddlcompat.sp_copy_seeded"),
            .init("INSERT INTO ddlcompat.sp_copy_seeded_copy SELECT * FROM ddlcompat.sp_copy_seeded"),
            .init(
                "CREATE TABLE ddlcompat.sp_copy_unpartitioned(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_unpartitioned VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_copy_unpartitioned TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_copy_unpartitioned_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_copy_unpartitioned_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_unpartitioned EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_copy_unpartitioned_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_copy_unpartitioned REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_copy_unpartitioned VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_copy_unpartitioned DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_copy_unpartitioned ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_copy_unpartitioned VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_copy_unpartitioned SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.sp_copy_unpartitioned WHERE id=23"),
            .init("CREATE TABLE ddlcompat.sp_copy_unpartitioned_copy LIKE ddlcompat.sp_copy_unpartitioned"),
            .init("INSERT INTO ddlcompat.sp_copy_unpartitioned_copy SELECT * FROM ddlcompat.sp_copy_unpartitioned"),
            .init("ALTER TABLE ddlcompat.sp_copy_unpartitioned_copy REMOVE PARTITIONING"),
            .init(
                "CREATE TABLE ddlcompat.sp_list_key(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))"
            ),
            .init("INSERT INTO ddlcompat.sp_list_key VALUES(1,10),(2,20),(11,110),(12,120)"),
            .init("ALTER TABLE ddlcompat.sp_list_key TRUNCATE PARTITION p0sp1"),
            .init("CREATE TABLE ddlcompat.sp_list_key_stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.sp_list_key_stage VALUES(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.sp_list_key EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.sp_list_key_stage WITH VALIDATION"
            ),
            .init(
                "ALTER TABLE ddlcompat.sp_list_key REORGANIZE PARTITION p1 INTO(PARTITION p10 VALUES LESS THAN(15)(SUBPARTITION a,SUBPARTITION b),PARTITION p11 VALUES LESS THAN(20)(SUBPARTITION c,SUBPARTITION d))"
            ),
            .init("INSERT INTO ddlcompat.sp_list_key VALUES(18,180)"),
            .init("ALTER TABLE ddlcompat.sp_list_key DROP PARTITION p10"),
            .init("ALTER TABLE ddlcompat.sp_list_key ADD PARTITION(PARTITION p2 VALUES LESS THAN(30))"),
            .init("INSERT INTO ddlcompat.sp_list_key VALUES(22,22),(23,23)"),
            .init("UPDATE ddlcompat.sp_list_key SET n=220 WHERE id=22"),
            .init("DELETE FROM ddlcompat.sp_list_key WHERE id=23"),
            .init("CREATE TABLE ddlcompat.sp_list_key_copy LIKE ddlcompat.sp_list_key"),
            .init("INSERT INTO ddlcompat.sp_list_key_copy SELECT * FROM ddlcompat.sp_list_key"),
            .init("ALTER TABLE ddlcompat.sp_list_key_copy REMOVE PARTITIONING"),
            .init(
                "ALTER TABLE ddlcompat.sp_list_key PARTITION BY LIST COLUMNS(id) SUBPARTITION BY LINEAR KEY ALGORITHM=2(id) SUBPARTITIONS 2(PARTITION p4 VALUES IN(4),PARTITION p18 VALUES IN(18),PARTITION p22 VALUES IN(22))",
                phaseEnd: "update-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "truncated-rows", check: .init("SELECT id FROM ddlcompat.sp_truncated ORDER BY id", "2\n11\n12")
                ),
                .init(
                    id: "exchanged-main-rows",
                    check: .init("SELECT id FROM ddlcompat.sp_exchanged ORDER BY id", "4\n11\n12")),
                .init(id: "exchanged-stage-rows", check: .init("SELECT id FROM ddlcompat.sp_exchanged_stage", "2")),
                .init(
                    id: "dropped-partition-rows",
                    check: .init("SELECT id FROM ddlcompat.sp_dropped ORDER BY id", "4\n18")),
                .init(
                    id: "copied-rows",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.sp_copy_seeded_copy ORDER BY id", "4\t40\n18\t180\n22\t220")),
                .init(
                    id: "final-main-rows",
                    check: .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "4\t40\n18\t180\n22\t221")),
                .init(
                    id: "final-subpartition-names",
                    check: .init(
                        "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "p4sp0,p4sp1,p18sp0,p18sp1,p22sp0,p22sp1")),
                .init(
                    id: "seed-rows",
                    check: .init("SELECT id,n FROM ddlcompat.sp_seed ORDER BY id", "1\t10\n2\t20\n11\t110\n12\t120")),
                .init(
                    id: "truncated-subpartition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.sp_truncated PARTITION(p0sp1)", "0")),
                .init(
                    id: "exchange-table-initially-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.sp_stage_empty_stage", "0")),
                .init(
                    id: "exchange-input",
                    check: .init("SELECT id,n FROM ddlcompat.sp_stage_seeded_stage ORDER BY id", "4\t40")),
                .init(
                    id: "exchange-subpartition-output",
                    check: .init("SELECT id,n FROM ddlcompat.sp_exchanged PARTITION(p0sp0) ORDER BY id", "4\t40")),
                .init(
                    id: "exchange-table-output",
                    check: .init("SELECT id,n FROM ddlcompat.sp_exchanged_stage ORDER BY id", "2\t20")),
                .init(
                    id: "reorganized-rows",
                    check: .init("SELECT id,n FROM ddlcompat.sp_reorganized ORDER BY id", "4\t40\n11\t110\n12\t120")),
                .init(
                    id: "insert-after-restart",
                    check: .init("SELECT id,n FROM ddlcompat.sp_inserted PARTITION(p11) ORDER BY id", "18\t180")),
                .init(
                    id: "dropped-partition-absent",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_dropped' AND PARTITION_NAME='p10'",
                        "0")),
                .init(
                    id: "added-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.sp_added PARTITION(p2)", "0")),
                .init(
                    id: "added-partition-seed",
                    check: .init("SELECT id,n FROM ddlcompat.sp_seeded_new PARTITION(p2) ORDER BY id", "22\t22\n23\t23")
                ),
                .init(
                    id: "updated-partition-rows",
                    check: .init("SELECT id,n FROM ddlcompat.sp_updated PARTITION(p2) ORDER BY id", "22\t220\n23\t23")),
                .init(
                    id: "deleted-partition-row",
                    check: .init("SELECT id,n FROM ddlcompat.sp_deleted PARTITION(p2) ORDER BY id", "22\t220")),
                .init(
                    id: "copy-initially-empty", check: .init("SELECT COUNT(*) FROM ddlcompat.sp_copy_empty_copy", "0")),
                .init(
                    id: "unpartitioned-copy-rows",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.sp_copy_unpartitioned_copy ORDER BY id", "4\t40\n18\t180\n22\t220")),
                .init(
                    id: "copy-partitions-removed",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_copy_unpartitioned_copy' AND PARTITION_NAME IS NOT NULL",
                        "0")),
                .init(
                    id: "list-key-rows-before-update",
                    check: .init("SELECT id,n FROM ddlcompat.sp_list_key ORDER BY id", "4\t40\n18\t180\n22\t220")),
                .init(
                    id: "final-copy-rows",
                    check: .init("SELECT id,n FROM ddlcompat.copy ORDER BY id", "4\t40\n18\t180\n22\t220")),
                .init(id: "final-stage-rows", check: .init("SELECT id,n FROM ddlcompat.stage ORDER BY id", "2\t20")),
                .init(
                    id: "final-list-partition-routing",
                    check: .init("SELECT id,n FROM ddlcompat.t PARTITION(p22) ORDER BY id", "22\t221")),
                .init(
                    id: "initial-subpartition-names",
                    check: .init(
                        "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_seed'",
                        "p0sp0,p0sp1,p1sp0,p1sp1")),
                .init(
                    id: "reorganized-subpartition-names",
                    check: .init(
                        "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_reorganized'",
                        "p0sp0,p0sp1,a,b,c,d")),
                .init(
                    id: "initial-subpartition-definitions",
                    check: .init(
                        "SELECT PARTITION_NAME,PARTITION_METHOD,SUBPARTITION_METHOD,REPLACE(SUBPARTITION_EXPRESSION,'`',''),COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_seed' GROUP BY PARTITION_ORDINAL_POSITION,PARTITION_NAME,PARTITION_METHOD,SUBPARTITION_METHOD,SUBPARTITION_EXPRESSION ORDER BY PARTITION_ORDINAL_POSITION",
                        "p0\tRANGE\tHASH\tid\t2\np1\tRANGE\tHASH\tid\t2")),
                .init(
                    id: "final-subpartition-definitions",
                    check: .init(
                        "SELECT PARTITION_NAME,PARTITION_METHOD,SUBPARTITION_METHOD,REPLACE(SUBPARTITION_EXPRESSION,'`',''),COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' GROUP BY PARTITION_ORDINAL_POSITION,PARTITION_NAME,PARTITION_METHOD,SUBPARTITION_METHOD,SUBPARTITION_EXPRESSION ORDER BY PARTITION_ORDINAL_POSITION",
                        "p4\tLIST COLUMNS\tLINEAR KEY\tid\t2\np18\tLIST COLUMNS\tLINEAR KEY\tid\t2\np22\tLIST COLUMNS\tLINEAR KEY\tid\t2"
                    )),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.sp_seed,ddlcompat.sp_truncated,ddlcompat.sp_stage_empty,ddlcompat.sp_stage_empty_stage,ddlcompat.sp_stage_seeded,ddlcompat.sp_stage_seeded_stage,ddlcompat.sp_exchanged,ddlcompat.sp_exchanged_stage,ddlcompat.sp_reorganized,ddlcompat.sp_reorganized_stage,ddlcompat.sp_inserted,ddlcompat.sp_inserted_stage,ddlcompat.sp_dropped,ddlcompat.sp_dropped_stage,ddlcompat.sp_added,ddlcompat.sp_added_stage,ddlcompat.sp_seeded_new,ddlcompat.sp_seeded_new_stage,ddlcompat.sp_updated,ddlcompat.sp_updated_stage,ddlcompat.sp_deleted,ddlcompat.sp_deleted_stage,ddlcompat.sp_copy_empty,ddlcompat.sp_copy_empty_stage,ddlcompat.sp_copy_empty_copy,ddlcompat.sp_copy_seeded,ddlcompat.sp_copy_seeded_stage,ddlcompat.sp_copy_seeded_copy,ddlcompat.sp_copy_unpartitioned,ddlcompat.sp_copy_unpartitioned_stage,ddlcompat.sp_copy_unpartitioned_copy,ddlcompat.sp_list_key,ddlcompat.sp_list_key_stage,ddlcompat.sp_list_key_copy"
            ]
        ))

    static let partitionHashForms = Case(
        "partition-hash-forms", "HASH and KEY partitioning: named partitions and implicit columns",
        [
            // Keep the original operations first, including each restart boundary.
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION PARTITIONS 2", phaseEnd: "add-partitions"),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION(PARTITION extra)", phaseEnd: "coalesce-and-change-key"),
            .init("UPDATE ddlcompat.t SET n=n+1", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.pf_seed(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.pf_seed(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.pf_seed VALUES(1,10),(2,20)"),
            .init(
                "CREATE TABLE ddlcompat.pf_added(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.pf_added(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.pf_added VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pf_added ADD PARTITION PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.pf_coalesced(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.pf_coalesced(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.pf_coalesced VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pf_coalesced ADD PARTITION PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pf_coalesced COALESCE PARTITION 2"),
            .init(
                "CREATE TABLE ddlcompat.pf_implicit_key(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.pf_implicit_key(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.pf_implicit_key VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pf_implicit_key ADD PARTITION PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pf_implicit_key COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.pf_implicit_key PARTITION BY KEY() PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.pf_extra(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early COMMENT='first' COMMENT='early',PARTITION late COMMENT='late')",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.pf_extra(id INT PRIMARY KEY,n INT) PARTITION BY LINEAR HASH(id) PARTITIONS 2(PARTITION early ENGINE='InnoDB' ENGINE=InnoDB COMMENT='first' COMMENT='early',PARTITION late ENGINE='InnoDB' COMMENT='late')"
            ),
            .init("INSERT INTO ddlcompat.pf_extra VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.pf_extra ADD PARTITION PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pf_extra COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.pf_extra PARTITION BY KEY() PARTITIONS 2"),
            .init(
                "ALTER TABLE ddlcompat.pf_extra ADD PARTITION(PARTITION extra)", phaseEnd: "update-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "added-partition-names",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_added'",
                        "early,late,p2,p3")),
                .init(id: "updated-rows", check: .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")),
                .init(id: "seed-rows", check: .init("SELECT id,n FROM ddlcompat.pf_seed ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "added-rows", check: .init("SELECT id,n FROM ddlcompat.pf_added ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "coalesced-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pf_coalesced ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "implicit-key-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pf_implicit_key ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "extra-rows", check: .init("SELECT id,n FROM ddlcompat.pf_extra ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "seed-method-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_seed' GROUP BY PARTITION_METHOD",
                        "LINEAR HASH\t2")),
                .init(
                    id: "added-method-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_added' GROUP BY PARTITION_METHOD",
                        "LINEAR HASH\t4")),
                .init(
                    id: "coalesced-method-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_coalesced' GROUP BY PARTITION_METHOD",
                        "LINEAR HASH\t2")),
                .init(
                    id: "implicit-key-method-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_implicit_key' GROUP BY PARTITION_METHOD",
                        "KEY\t2")),
                .init(
                    id: "extra-method-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_extra' GROUP BY PARTITION_METHOD",
                        "KEY\t3")),
                .init(
                    id: "seed-partition-names",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_seed'",
                        "early,late")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.pf_seed,ddlcompat.pf_added,ddlcompat.pf_coalesced,ddlcompat.pf_implicit_key,ddlcompat.pf_extra"
            ]
        ))

}
