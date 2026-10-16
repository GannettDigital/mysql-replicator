import Foundation

extension DDLCompatibilityCases {
    static let partitionExpressions = Case(
        "partition-expressions",
        "Native constant bounds, date functions, column tuples, DML, restart and offline replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(d DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(d,id)) PARTITION BY RANGE(TO_DAYS(d))(PARTITION old VALUES LESS THAN(TO_DAYS('2026-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION future INTO(PARTITION current_year VALUES LESS THAN(TO_DAYS('2027-01-01')),PARTITION future VALUES LESS THAN MAXVALUE)",
                [
                    .init(
                        "SELECT GROUP_CONCAT(PARTITION_DESCRIPTION ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "739982,740347,MAXVALUE")
                ]),
            .init(
                "ALTER TABLE ddlcompat.t TRUNCATE PARTITION old",
                [.init("SELECT id FROM ddlcompat.t ORDER BY id", "2\n3")], restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=21 WHERE d='2026-06-01' AND id=2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY HASH(EXTRACT(YEAR_MONTH FROM d)) PARTITIONS 2"),
            .init(
                "CREATE TABLE ddlcompat.l(id INT PRIMARY KEY,n INT) PARTITION BY LIST(id)(PARTITION p VALUES IN(ABS(-3),1+1,1),PARTITION q VALUES IN(20 DIV 5))"
            ),
            .init(
                "INSERT INTO ddlcompat.l VALUES(1,10),(2,20),(3,30),(4,40)",
                [.init("SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.l PARTITION(p)", "1,2,3")]),
            .init("ALTER TABLE ddlcompat.l ADD PARTITION(PARTITION extra VALUES IN(ABS(-5)))"),
            .init("INSERT INTO ddlcompat.l VALUES(5,50)", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.c(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY RANGE COLUMNS(d,id)(PARTITION p VALUES LESS THAN(DATE '2026-01-01',ABS(-10)),PARTITION q VALUES LESS THAN(MAXVALUE,MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.c VALUES('2026-01-01',9),('2026-01-01',10)",
                [
                    .init("SELECT id FROM ddlcompat.c PARTITION(p)", "9"),
                    .init("SELECT id FROM ddlcompat.c PARTITION(q)", "10"),
                ]),
            .init(
                "DELETE FROM ddlcompat.l WHERE id=2",
                [.init("SELECT id,n FROM ddlcompat.l ORDER BY id", "1\t10\n3\t30\n4\t40\n5\t50")], restartBefore: true),
        ], nativeInnoDB: true)

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
