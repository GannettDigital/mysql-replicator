import Foundation

extension DDLCompatibilityCases {
    static let partitionColumnRenames = Case(
        "partition-column-renames", "ALTER TABLE: CHANGE columns with partition replacement and removal",
        [
            // Keep the original operations and restart boundaries before the retained histories.
            .init(
                "CREATE TABLE ddlcompat.t(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,100),(11,20,200)", phaseEnd: "create-and-seed"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
                restartBefore: true),
            .init("UPDATE ddlcompat.t SET x=21,y=30,n=101 WHERE x=1 AND y=10", phaseEnd: "change-and-move"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
                restartBefore: true),
            .init("INSERT INTO ddlcompat.t(y,x,n) VALUES(2,3,4)", phaseEnd: "swap-and-insert"),
            .init("ALTER TABLE ddlcompat.t CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2", phaseEnd: "remove-and-add-key"),
            .init("ALTER TABLE ddlcompat.t CHANGE id key_id INT", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=201 WHERE key_id=11 AND sid=20"),
            .init("ALTER TABLE ddlcompat.t CHANGE key_id final_id INT REMOVE PARTITIONING"),
            .init("DELETE FROM ddlcompat.t WHERE final_id=2 AND sid=3"),
            .init("DROP TABLE ddlcompat.t"),
            .init(
                "CREATE TABLE ddlcompat.pc_seed(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_seed VALUES(1,10,100),(11,20,200)"),
            .init(
                "CREATE TABLE ddlcompat.pc_changed(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_changed VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_changed CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "CREATE TABLE ddlcompat.pc_moved(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_moved VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_moved CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_moved SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "CREATE TABLE ddlcompat.pc_swapped(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_swapped VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_swapped CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_swapped SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_swapped CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "CREATE TABLE ddlcompat.pc_inserted(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_inserted VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_inserted CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_inserted SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_inserted CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_inserted(y,x,n) VALUES(2,3,4)"),
            .init(
                "CREATE TABLE ddlcompat.pc_removed(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_removed VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_removed CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_removed SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_removed CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_removed(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_removed CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init(
                "CREATE TABLE ddlcompat.pc_implicit_key(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_implicit_key VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_implicit_key CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_implicit_key SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_implicit_key CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_implicit_key(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_implicit_key CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init("ALTER TABLE ddlcompat.pc_implicit_key PARTITION BY KEY() PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.pc_key_renamed(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_key_renamed VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_key_renamed CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_key_renamed SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_key_renamed CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_key_renamed(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_key_renamed CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init("ALTER TABLE ddlcompat.pc_key_renamed PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pc_key_renamed CHANGE id key_id INT"),
            .init(
                "CREATE TABLE ddlcompat.pc_updated(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_updated VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_updated CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_updated SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_updated CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_updated(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_updated CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init("ALTER TABLE ddlcompat.pc_updated PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pc_updated CHANGE id key_id INT"),
            .init("UPDATE ddlcompat.pc_updated SET n=201 WHERE key_id=11 AND sid=20"),
            .init(
                "CREATE TABLE ddlcompat.pc_final_name(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_final_name VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_final_name CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_final_name SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_final_name CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_final_name(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_final_name CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init("ALTER TABLE ddlcompat.pc_final_name PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pc_final_name CHANGE id key_id INT"),
            .init("UPDATE ddlcompat.pc_final_name SET n=201 WHERE key_id=11 AND sid=20"),
            .init("ALTER TABLE ddlcompat.pc_final_name CHANGE key_id final_id INT REMOVE PARTITIONING"),
            .init(
                "CREATE TABLE ddlcompat.pc_deleted(a INT,b INT,n INT,PRIMARY KEY(a,b)) PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_deleted VALUES(1,10,100),(11,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.pc_deleted CHANGE a x INT,CHANGE b y INT PARTITION BY RANGE(x) SUBPARTITION BY HASH(y) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.pc_deleted SET x=21,y=30,n=101 WHERE x=1 AND y=10"),
            .init(
                "ALTER TABLE ddlcompat.pc_deleted CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pc_deleted(y,x,n) VALUES(2,3,4)"),
            .init("ALTER TABLE ddlcompat.pc_deleted CHANGE y id INT,CHANGE x sid INT REMOVE PARTITIONING"),
            .init("ALTER TABLE ddlcompat.pc_deleted PARTITION BY KEY() PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.pc_deleted CHANGE id key_id INT"),
            .init("UPDATE ddlcompat.pc_deleted SET n=201 WHERE key_id=11 AND sid=20"),
            .init("ALTER TABLE ddlcompat.pc_deleted CHANGE key_id final_id INT REMOVE PARTITIONING"),
            .init("DELETE FROM ddlcompat.pc_deleted WHERE final_id=2 AND sid=3", phaseEnd: "rename-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "changed-column-rows",
                    check: .init("SELECT x,y,n FROM ddlcompat.pc_changed ORDER BY x", "1\t10\t100\n11\t20\t200")),
                .init(
                    id: "moved-partition-rows",
                    check: .init(
                        "SELECT x,y,n FROM ddlcompat.pc_moved PARTITION(p1) ORDER BY x", "11\t20\t200\n21\t30\t101")),
                .init(
                    id: "swapped-column-rows",
                    check: .init("SELECT y,x,n FROM ddlcompat.pc_swapped ORDER BY y", "11\t20\t200\n21\t30\t101")),
                .init(
                    id: "insert-after-swap",
                    check: .init("SELECT y,x,n FROM ddlcompat.pc_inserted PARTITION(p0)", "2\t3\t4")),
                .init(
                    id: "removed-partitions",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_removed' AND PARTITION_NAME IS NOT NULL",
                        "0")),
                .init(
                    id: "renamed-key-rows",
                    check: .init(
                        "SELECT key_id,sid,n FROM ddlcompat.pc_key_renamed ORDER BY key_id",
                        "2\t3\t4\n11\t20\t200\n21\t30\t101")),
                .init(
                    id: "deleted-row-absent",
                    check: .init(
                        "SELECT final_id,sid,n FROM ddlcompat.pc_deleted ORDER BY final_id", "11\t20\t201\n21\t30\t101")
                ),
                .init(
                    id: "original-table-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "0")),
                .init(
                    id: "seed-rows",
                    check: .init("SELECT a,b,n FROM ddlcompat.pc_seed ORDER BY a", "1\t10\t100\n11\t20\t200")),
                .init(
                    id: "old-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.pc_moved PARTITION(p0)", "0")),
                .init(
                    id: "rows-after-remove",
                    check: .init(
                        "SELECT id,sid,n FROM ddlcompat.pc_removed ORDER BY id", "2\t3\t4\n11\t20\t200\n21\t30\t101")),
                .init(
                    id: "implicit-key-rows",
                    check: .init(
                        "SELECT id,sid,n FROM ddlcompat.pc_implicit_key ORDER BY id",
                        "2\t3\t4\n11\t20\t200\n21\t30\t101")),
                .init(
                    id: "updated-key-rows",
                    check: .init(
                        "SELECT key_id,sid,n FROM ddlcompat.pc_updated ORDER BY key_id",
                        "2\t3\t4\n11\t20\t201\n21\t30\t101")),
                .init(
                    id: "final-name-before-delete",
                    check: .init(
                        "SELECT final_id,sid,n FROM ddlcompat.pc_final_name ORDER BY final_id",
                        "2\t3\t4\n11\t20\t201\n21\t30\t101")),
                .init(
                    id: "final-partitions-removed",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_final_name' AND PARTITION_NAME IS NOT NULL",
                        "0")),
                .init(
                    id: "changed-partition-references",
                    check: .init(
                        "SELECT DISTINCT PARTITION_METHOD,REPLACE(PARTITION_EXPRESSION,'`',''),SUBPARTITION_METHOD,REPLACE(SUBPARTITION_EXPRESSION,'`','') FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_changed'",
                        "RANGE\tx\tHASH\ty")),
                .init(
                    id: "swapped-partition-references",
                    check: .init(
                        "SELECT DISTINCT PARTITION_METHOD,REPLACE(PARTITION_EXPRESSION,'`',''),SUBPARTITION_METHOD,REPLACE(SUBPARTITION_EXPRESSION,'`','') FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_swapped'",
                        "RANGE\ty\tHASH\tx")),
                .init(
                    id: "implicit-key-partition-count",
                    check: .init(
                        "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_implicit_key' GROUP BY PARTITION_METHOD",
                        "KEY\t2")),
                .init(
                    id: "pc-swapped-primary-key",
                    check: .init(
                        "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_swapped' AND INDEX_NAME='PRIMARY'",
                        "y,x")),
                .init(
                    id: "pc-key-renamed-primary-key",
                    check: .init(
                        "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_key_renamed' AND INDEX_NAME='PRIMARY'",
                        "key_id,sid")),
                .init(
                    id: "pc-final-name-primary-key",
                    check: .init(
                        "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_final_name' AND INDEX_NAME='PRIMARY'",
                        "final_id,sid")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.pc_seed,ddlcompat.pc_changed,ddlcompat.pc_moved,ddlcompat.pc_swapped,ddlcompat.pc_inserted,ddlcompat.pc_removed,ddlcompat.pc_implicit_key,ddlcompat.pc_key_renamed,ddlcompat.pc_updated,ddlcompat.pc_final_name,ddlcompat.pc_deleted"
            ]
        ))

    static let partitionRenameSyntax = Case(
        "partition-rename-syntax", "ALTER TABLE: RENAME COLUMN with partition replacement and removal",
        [
            // Keep the original operations and restart boundaries before the retained histories.
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(11,20)", phaseEnd: "create-and-seed"),
            .init(
                "ALTER TABLE ddlcompat.t RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)",
                restartBefore: true),
            .init("UPDATE ddlcompat.t SET renamed=21 WHERE renamed=1", phaseEnd: "rename-and-move"),
            .init("ALTER TABLE ddlcompat.t RENAME COLUMN renamed TO id REMOVE PARTITIONING", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=11"),
            .init("DROP TABLE ddlcompat.t"),
            .init(
                "CREATE TABLE ddlcompat.ps_seed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ps_seed VALUES(1,10),(11,20)"),
            .init(
                "CREATE TABLE ddlcompat.ps_renamed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ps_renamed VALUES(1,10),(11,20)"),
            .init(
                "ALTER TABLE ddlcompat.ps_renamed RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "CREATE TABLE ddlcompat.ps_moved(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ps_moved VALUES(1,10),(11,20)"),
            .init(
                "ALTER TABLE ddlcompat.ps_moved RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.ps_moved SET renamed=21 WHERE renamed=1"),
            .init(
                "CREATE TABLE ddlcompat.ps_removed(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ps_removed VALUES(1,10),(11,20)"),
            .init(
                "ALTER TABLE ddlcompat.ps_removed RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.ps_removed SET renamed=21 WHERE renamed=1"),
            .init("ALTER TABLE ddlcompat.ps_removed RENAME COLUMN renamed TO id REMOVE PARTITIONING"),
            .init(
                "CREATE TABLE ddlcompat.ps_deleted(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.ps_deleted VALUES(1,10),(11,20)"),
            .init(
                "ALTER TABLE ddlcompat.ps_deleted RENAME COLUMN id TO renamed PARTITION BY RANGE(renamed) (PARTITION low VALUES LESS THAN(10),PARTITION high VALUES LESS THAN MAXVALUE)"
            ),
            .init("UPDATE ddlcompat.ps_deleted SET renamed=21 WHERE renamed=1"),
            .init("ALTER TABLE ddlcompat.ps_deleted RENAME COLUMN renamed TO id REMOVE PARTITIONING"),
            .init("DELETE FROM ddlcompat.ps_deleted WHERE id=11", phaseEnd: "remove-and-retain-results"),
        ], nativeInnoDB: true,
        profileExclusions: [
            .reverse: "MySQL 5.7 has no RENAME COLUMN syntax.",
            .mysql57MyISAM: "MySQL 5.7 has no RENAME COLUMN syntax.",
            .mysql57InnoDB: "MySQL 5.7 has no RENAME COLUMN syntax.",
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "renamed-column-rows",
                    check: .init("SELECT renamed,n FROM ddlcompat.ps_renamed ORDER BY renamed", "1\t10\n11\t20")),
                .init(
                    id: "moved-partition-rows",
                    check: .init(
                        "SELECT renamed,n FROM ddlcompat.ps_moved PARTITION(high) ORDER BY renamed", "11\t20\n21\t10")),
                .init(id: "deleted-row-absent", check: .init("SELECT id,n FROM ddlcompat.ps_deleted", "21\t10")),
                .init(
                    id: "original-table-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "0")),
                .init(id: "seed-rows", check: .init("SELECT id,n FROM ddlcompat.ps_seed ORDER BY id", "1\t10\n11\t20")),
                .init(
                    id: "low-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.ps_moved PARTITION(low)", "0")),
                .init(
                    id: "rows-after-remove",
                    check: .init("SELECT id,n FROM ddlcompat.ps_removed ORDER BY id", "11\t20\n21\t10")),
                .init(
                    id: "removed-partitions",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ps_removed' AND PARTITION_NAME IS NOT NULL",
                        "0")),
                .init(
                    id: "renamed-partition-expression",
                    check: .init(
                        "SELECT DISTINCT PARTITION_METHOD,REPLACE(PARTITION_EXPRESSION,'`','') FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ps_renamed'",
                        "RANGE\trenamed")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ps_seed,ddlcompat.ps_renamed,ddlcompat.ps_moved,ddlcompat.ps_removed,ddlcompat.ps_deleted"
            ]
        ))

}
