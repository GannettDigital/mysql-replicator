import Foundation

extension DDLCompatibilityCases {
    static let partitionExpressions = Case(
        "partition-expressions", "Partitioning expressions: evaluated bounds and RANGE COLUMNS",
        [
            // Keep the original operations first, including each restart boundary.
            .init(
                "CREATE TABLE ddlcompat.t(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION future INTO(PARTITION current_year VALUES LESS THAN(TO_DAYS('2027-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)",
                phaseEnd: "reorganize-bounds"),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION old", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=21 WHERE d='2026-06-01' AND id=2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY HASH(EXTRACT(YEAR_MONTH FROM d)) PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.l(id INT PRIMARY KEY,n INT) PARTITION BY LIST(id)(PARTITION p VALUES IN(ABS(-3),1+1,1),PARTITION q VALUES IN(20 DIV 5))"
            ),
            .init("INSERT INTO ddlcompat.l VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init(
                "ALTER TABLE ddlcompat.l ADD PARTITION(PARTITION extra VALUES IN(ABS(-5)))",
                phaseEnd: "truncate-and-add-list-bound"),
            .init("INSERT INTO ddlcompat.l VALUES(5,50)", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.c(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY RANGE COLUMNS(d,id)(PARTITION p VALUES LESS THAN(DATE '2026-01-01',ABS(-10)),PARTITION q VALUES LESS THAN(MAXVALUE,MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.c VALUES('2026-01-01',9),('2026-01-01',10)", phaseEnd: "insert-and-route-tuples"),
            .init("DELETE FROM ddlcompat.l WHERE id=2", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.pe_dates(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pe_dates VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "CREATE TABLE ddlcompat.pe_reorganized(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "INSERT INTO ddlcompat.pe_reorganized VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"
            ),
            .init(
                "ALTER TABLE ddlcompat.pe_reorganized REORGANIZE PARTITION future INTO(PARTITION current_year VALUES LESS THAN(TO_DAYS('2027-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "CREATE TABLE ddlcompat.pe_truncated(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init(
                "INSERT INTO ddlcompat.pe_truncated VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "ALTER TABLE ddlcompat.pe_truncated REORGANIZE PARTITION future INTO(PARTITION current_year VALUES LESS THAN(TO_DAYS('2027-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("ALTER TABLE ddlcompat.pe_truncated TRUNCATE PARTITION old"),
            .init(
                "CREATE TABLE ddlcompat.pe_updated(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.pe_updated VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "ALTER TABLE ddlcompat.pe_updated REORGANIZE PARTITION future INTO(PARTITION current_year VALUES LESS THAN(TO_DAYS('2027-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("ALTER TABLE ddlcompat.pe_updated TRUNCATE PARTITION old"),
            .init("UPDATE ddlcompat.pe_updated SET n=21 WHERE d='2026-06-01' AND id=2"),
            .init(
                "CREATE TABLE ddlcompat.pe_list_seed(id INT PRIMARY KEY,n INT) PARTITION BY LIST(id)(PARTITION p VALUES IN(ABS(-3),1+1,1),PARTITION q VALUES IN(20 DIV 5))"
            ),
            .init("INSERT INTO ddlcompat.pe_list_seed VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init(
                "CREATE TABLE ddlcompat.pe_list_added(id INT PRIMARY KEY,n INT) PARTITION BY LIST(id)(PARTITION p VALUES IN(ABS(-3),1+1,1),PARTITION q VALUES IN(20 DIV 5))"
            ),
            .init("INSERT INTO ddlcompat.pe_list_added VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init("ALTER TABLE ddlcompat.pe_list_added ADD PARTITION(PARTITION extra VALUES IN(ABS(-5)))"),
            .init(
                "CREATE TABLE ddlcompat.pe_list_filled(id INT PRIMARY KEY,n INT) PARTITION BY LIST(id)(PARTITION p VALUES IN(ABS(-3),1+1,1),PARTITION q VALUES IN(20 DIV 5))"
            ),
            .init("INSERT INTO ddlcompat.pe_list_filled VALUES(1,10),(2,20),(3,30),(4,40)"),
            .init("ALTER TABLE ddlcompat.pe_list_filled ADD PARTITION(PARTITION extra VALUES IN(ABS(-5)))"),
            .init("INSERT INTO ddlcompat.pe_list_filled VALUES(5,50)", phaseEnd: "delete-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "evaluated-date-bounds",
                    check: .init(
                        "SELECT GROUP_CONCAT(PARTITION_DESCRIPTION ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pe_reorganized'",
                        "739982,740347,MAXVALUE")),
                .init(
                    id: "truncated-date-rows", check: .init("SELECT id FROM ddlcompat.pe_truncated ORDER BY id", "2\n3")
                ),
                .init(
                    id: "computed-list-routing",
                    check: .init(
                        "SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.pe_list_seed PARTITION(p)", "1,2,3")),
                .init(id: "tuple-below-bound", check: .init("SELECT id FROM ddlcompat.c PARTITION(p)", "9")),
                .init(id: "tuple-at-bound", check: .init("SELECT id FROM ddlcompat.c PARTITION(q)", "10")),
                .init(
                    id: "final-list-rows",
                    check: .init("SELECT id,n FROM ddlcompat.l ORDER BY id", "1\t10\n3\t30\n4\t40\n5\t50")),
                .init(
                    id: "date-seed-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pe_dates ORDER BY id", "1\t10\n2\t20\n3\t30")),
                .init(
                    id: "reorganized-current-year",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.pe_reorganized PARTITION(current_year) ORDER BY id", "2\t20")),
                .init(
                    id: "reorganized-future",
                    check: .init("SELECT id,n FROM ddlcompat.pe_reorganized PARTITION(future) ORDER BY id", "3\t30")),
                .init(
                    id: "truncated-old-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.pe_truncated PARTITION(old)", "0")),
                .init(
                    id: "updated-range-rows",
                    check: .init("SELECT id,n FROM ddlcompat.pe_updated ORDER BY id", "2\t21\n3\t30")),
                .init(id: "final-hash-rows", check: .init("SELECT id,n FROM ddlcompat.t ORDER BY id", "2\t21\n3\t30")),
                .init(
                    id: "list-div-routing",
                    check: .init("SELECT id,n FROM ddlcompat.pe_list_seed PARTITION(q) ORDER BY id", "4\t40")),
                .init(
                    id: "added-computed-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.pe_list_added PARTITION(extra)", "0")),
                .init(
                    id: "added-computed-partition-row",
                    check: .init("SELECT id,n FROM ddlcompat.pe_list_filled PARTITION(extra) ORDER BY id", "5\t50")),
                .init(
                    id: "list-before-delete",
                    check: .init(
                        "SELECT id,n FROM ddlcompat.pe_list_filled ORDER BY id", "1\t10\n2\t20\n3\t30\n4\t40\n5\t50")),
                .init(
                    id: "added-computed-bound",
                    check: .init(
                        "SELECT PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pe_list_added' AND PARTITION_NAME='extra'",
                        "5")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.pe_dates,ddlcompat.pe_reorganized,ddlcompat.pe_truncated,ddlcompat.pe_updated,ddlcompat.pe_list_seed,ddlcompat.pe_list_added,ddlcompat.pe_list_filled"
            ]
        ))

    static let partitionExchangeUnchecked = Case(
        "partition-exchange-unchecked",
        "Unchecked exchange preserves native misplaced rows; exchange back, DML, restart and offline replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY RANGE(id)(PARTITION p VALUES LESS THAN(10),PARTITION q VALUES LESS THAN MAXVALUE)"
            ),
            .init("CREATE TABLE ddlcompat.stage(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(11,110)"),
            .init("INSERT INTO ddlcompat.stage VALUES(20,200)"),
            .init(
                "ALTER TABLE ddlcompat.t EXCHANGE PARTITION p WITH TABLE ddlcompat.stage WITHOUT VALIDATION",
                [
                    .init("SELECT id,n FROM ddlcompat.t PARTITION(p)", "20\t200"),
                    .init("SELECT COUNT(*) FROM ddlcompat.t WHERE id=20", "0"),
                    .init("SELECT id FROM ddlcompat.stage", "1"),
                ]),
            .init(
                "ALTER TABLE ddlcompat.t EXCHANGE PARTITION p WITH TABLE ddlcompat.stage WITHOUT VALIDATION",
                [.init("SELECT id FROM ddlcompat.t ORDER BY id", "1\n11")], restartBefore: true),
            .init("DELETE FROM ddlcompat.stage WHERE id=20"),
            .init("INSERT INTO ddlcompat.stage VALUES(2,20)"),
            .init("ALTER TABLE ddlcompat.t EXCHANGE PARTITION p WITH TABLE ddlcompat.stage WITHOUT VALIDATION"),
            .init(
                "UPDATE ddlcompat.t SET n=21 WHERE id=2",
                [.init("SELECT id,n FROM ddlcompat.t ORDER BY id", "2\t21\n11\t110")], restartBefore: true),
            .init("DELETE FROM ddlcompat.stage WHERE id=1"),
            .init("INSERT INTO ddlcompat.t VALUES(3,30)"),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION p", [.init("SELECT id,n FROM ddlcompat.t", "11\t110")]),
        ], nativeInnoDB: true)
}
