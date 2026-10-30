import Foundation

extension DDLCompatibilityCases {
    static let rangePartitionManagement = Case(
        "partitions", "Partition management: RANGE COLUMNS and EXCHANGE PARTITION",
        [
            // Keep the original operations first. Retained tables preserve each earlier result.
            .init(
                "CREATE TABLE ddlcompat.t(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.t DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"
            ),
            .init("INSERT INTO ddlcompat.stage VALUES('2027-08-01',4,40)"),
            .init("ALTER TABLE ddlcompat.t EXCHANGE PARTITION next_year WITH TABLE ddlcompat.stage WITH VALIDATION"),
            .init("UPDATE ddlcompat.t SET n=41 WHERE report_date='2027-08-01' AND id=4"),
            .init("ALTER TABLE ddlcompat.t REMOVE PARTITIONING"),
            .init(
                "CREATE TABLE ddlcompat.pr_seed(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pr_seed VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "CREATE TABLE ddlcompat.pr_dropped(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pr_dropped VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.pr_dropped DROP PARTITION old"),
            .init(
                "CREATE TABLE ddlcompat.pr_truncated(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.pr_truncated VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.pr_truncated DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_truncated TRUNCATE PARTITION current_data"),
            .init(
                "CREATE TABLE ddlcompat.pr_reorganized(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.pr_reorganized VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"
            ),
            .init("ALTER TABLE ddlcompat.pr_reorganized DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_reorganized TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.pr_reorganized REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_stage_empty(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.pr_stage_empty VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"
            ),
            .init("ALTER TABLE ddlcompat.pr_stage_empty DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_stage_empty TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.pr_stage_empty REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_stage_empty_stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_stage_seeded(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.pr_stage_seeded VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"
            ),
            .init("ALTER TABLE ddlcompat.pr_stage_seeded DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_stage_seeded TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.pr_stage_seeded REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_stage_seeded_stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"
            ),
            .init("INSERT INTO ddlcompat.pr_stage_seeded_stage VALUES('2027-08-01',4,40)"),
            .init(
                "CREATE TABLE ddlcompat.pr_exchanged(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.pr_exchanged VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.pr_exchanged DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_exchanged TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.pr_exchanged REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_exchanged_stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"
            ),
            .init("INSERT INTO ddlcompat.pr_exchanged_stage VALUES('2027-08-01',4,40)"),
            .init(
                "ALTER TABLE ddlcompat.pr_exchanged EXCHANGE PARTITION next_year WITH TABLE ddlcompat.pr_exchanged_stage WITH VALIDATION"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_updated(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pr_updated VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.pr_updated DROP PARTITION old"),
            .init("ALTER TABLE ddlcompat.pr_updated TRUNCATE PARTITION current_data"),
            .init(
                "ALTER TABLE ddlcompat.pr_updated REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pr_updated_stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"
            ),
            .init("INSERT INTO ddlcompat.pr_updated_stage VALUES('2027-08-01',4,40)"),
            .init(
                "ALTER TABLE ddlcompat.pr_updated EXCHANGE PARTITION next_year WITH TABLE ddlcompat.pr_updated_stage WITH VALIDATION"
            ),
            .init(
                "UPDATE ddlcompat.pr_updated SET n=41 WHERE report_date='2027-08-01' AND id=4",
                phaseEnd: "write-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "drop-removes-old-row", check: .init("SELECT id FROM ddlcompat.pr_dropped ORDER BY id", "2\n3")),
                .init(
                    id: "truncate-removes-current-row",
                    check: .init("SELECT id FROM ddlcompat.pr_truncated ORDER BY id", "3")),
                .init(
                    id: "exchange-partition-rows",
                    check: .init("SELECT id FROM ddlcompat.pr_exchanged ORDER BY id", "4")),
                .init(
                    id: "exchange-table-rows",
                    check: .init("SELECT id FROM ddlcompat.pr_exchanged_stage ORDER BY id", "3")),
                .init(id: "update-after-exchange", check: .init("SELECT n FROM ddlcompat.pr_updated", "41")),
                .init(
                    id: "remove-partitioning",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND PARTITION_NAME IS NOT NULL",
                        "0")),
                .init(
                    id: "seed-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pr_seed ORDER BY id", "1\t10\n2\t20\n3\t30")),
                .init(
                    id: "truncated-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.pr_truncated PARTITION(current_data)", "0")),
                .init(
                    id: "reorganized-row-placement",
                    check: .init("SELECT id,n FROM ddlcompat.pr_reorganized PARTITION(next_year)", "3\t30")),
                .init(
                    id: "exchange-table-initially-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.pr_stage_empty_stage", "0")),
                .init(
                    id: "exchange-table-before-exchange",
                    check: .init("SELECT id,n FROM ddlcompat.pr_stage_seeded_stage", "4\t40")),
                .init(
                    id: "partition-before-exchange",
                    check: .init("SELECT id,n FROM ddlcompat.pr_stage_seeded PARTITION(next_year)", "3\t30")),
                .init(
                    id: "exchange-before-update",
                    check: .init("SELECT id,n FROM ddlcompat.pr_exchanged PARTITION(next_year)", "4\t40")),
                .init(
                    id: "exchange-table-after-update",
                    check: .init("SELECT id,n FROM ddlcompat.pr_updated_stage", "3\t30")),
                .init(id: "final-unpartitioned-rows", check: .init("SELECT id,n FROM ddlcompat.t", "4\t41")),
                .init(id: "final-exchange-table-rows", check: .init("SELECT id,n FROM ddlcompat.stage", "3\t30")),
                .init(
                    id: "initial-partitions",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_seed'",
                        "old,current_data,future")),
                .init(
                    id: "dropped-partition-absent",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_dropped'",
                        "current_data,future")),
                .init(
                    id: "truncated-partition-retained",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_truncated'",
                        "current_data,future")),
                .init(
                    id: "reorganized-partitions",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_reorganized'",
                        "current_data,next_year,future")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.pr_seed,ddlcompat.pr_dropped,ddlcompat.pr_truncated,ddlcompat.pr_reorganized,ddlcompat.pr_stage_empty,ddlcompat.pr_stage_empty_stage,ddlcompat.pr_stage_seeded,ddlcompat.pr_stage_seeded_stage,ddlcompat.pr_exchanged,ddlcompat.pr_exchanged_stage,ddlcompat.pr_updated,ddlcompat.pr_updated_stage"
            ]
        ))

    static let hashKeyListManagement = Case(
        "hash-list", "Partition management: HASH, KEY and LIST changes",
        [
            // Keep the original operations first. Retained tables preserve each earlier result.
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY(id) PARTITIONS 2"),
            .init(
                "ALTER TABLE ddlcompat.t PARTITION BY LIST(id) (PARTITION p1 VALUES IN (1),PARTITION p2 VALUES IN (2))"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION (PARTITION p3 VALUES IN (3))"),
            .init("INSERT INTO ddlcompat.t VALUES(3,30)"),
            .init("CREATE TABLE ddlcompat.ph_seed(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.ph_seed VALUES(1,10),(2,20)"),
            .init("CREATE TABLE ddlcompat.ph_coalesced(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.ph_coalesced VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ph_coalesced COALESCE PARTITION 2"),
            .init("CREATE TABLE ddlcompat.ph_key(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.ph_key VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ph_key COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.ph_key PARTITION BY KEY(id) PARTITIONS 2"),
            .init("CREATE TABLE ddlcompat.ph_list(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.ph_list VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ph_list COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.ph_list PARTITION BY KEY(id) PARTITIONS 2"),
            .init(
                "ALTER TABLE ddlcompat.ph_list PARTITION BY LIST(id) (PARTITION p1 VALUES IN (1),PARTITION p2 VALUES IN (2))"
            ),
            .init("CREATE TABLE ddlcompat.ph_added(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.ph_added VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ph_added COALESCE PARTITION 2"),
            .init("ALTER TABLE ddlcompat.ph_added PARTITION BY KEY(id) PARTITIONS 2"),
            .init(
                "ALTER TABLE ddlcompat.ph_added PARTITION BY LIST(id) (PARTITION p1 VALUES IN (1),PARTITION p2 VALUES IN (2))"
            ),
            .init(
                "ALTER TABLE ddlcompat.ph_added ADD PARTITION (PARTITION p3 VALUES IN (3))",
                phaseEnd: "write-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(id: "coalesce-retains-values", check: .init("SELECT SUM(n) FROM ddlcompat.ph_coalesced", "30")),
                .init(id: "insert-into-added-partition", check: .init("SELECT SUM(n) FROM ddlcompat.t", "60")),
                .init(id: "seed-rows", check: .init("SELECT id,n FROM ddlcompat.ph_seed ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "coalesced-rows",
                    check: .init("SELECT id,n FROM ddlcompat.ph_coalesced ORDER BY id", "1\t10\n2\t20")),
                .init(id: "key-rows", check: .init("SELECT id,n FROM ddlcompat.ph_key ORDER BY id", "1\t10\n2\t20")),
                .init(
                    id: "list-first-partition",
                    check: .init("SELECT id,n FROM ddlcompat.ph_list PARTITION(p1)", "1\t10")),
                .init(
                    id: "list-second-partition",
                    check: .init("SELECT id,n FROM ddlcompat.ph_list PARTITION(p2)", "2\t20")),
                .init(
                    id: "added-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.ph_added PARTITION(p3)", "0")),
                .init(id: "added-partition-row", check: .init("SELECT id,n FROM ddlcompat.t PARTITION(p3)", "3\t30")),
                .init(
                    id: "final-rows", check: .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t10\n2\t20\n3\t30")),
                .init(
                    id: "initial-hash-partitions",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_seed' GROUP BY PARTITION_METHOD",
                        "HASH\t4")),
                .init(
                    id: "coalesced-hash-partitions",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_coalesced' GROUP BY PARTITION_METHOD",
                        "HASH\t2")),
                .init(
                    id: "key-partitions",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_key' GROUP BY PARTITION_METHOD",
                        "KEY\t2")),
                .init(
                    id: "list-partitions",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_list' GROUP BY PARTITION_METHOD",
                        "LIST\t2")),
                .init(
                    id: "added-list-partition",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_added' GROUP BY PARTITION_METHOD",
                        "LIST\t3")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ph_seed,ddlcompat.ph_coalesced,ddlcompat.ph_key,ddlcompat.ph_list,ddlcompat.ph_added"
            ]
        ))

}
