import Foundation

extension DDLCompatibilityCases {
    static let generatedExpressions = Case(
        "generated-expressions", "Generated columns: expressions and CREATE TABLE LIKE",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,bucket INT AS (INTERVAL(n,1,5)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.t(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)",
                phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET n=12,v='xyzx',d='2025-01-02' WHERE id=1", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t ADD absent INT AS (n IS NOT NULL) STORED,ADD bounded INT AS (n NOT BETWEEN 1 AND 10) STORED"
            ),
            .init("UPDATE ddlcompat.t SET n=1 WHERE id=2"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t", phaseEnd: "before-restart-2"),
            .init("INSERT INTO ddlcompat.copy(id,n,v,d) VALUES(3,1,'xxone','2024-01-01')", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.ge_initial(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,bucket INT AS (INTERVAL(n,1,5)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ge_initial(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)"),
            .init(
                "CREATE TABLE ddlcompat.ge_updated(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,bucket INT AS (INTERVAL(n,1,5)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ge_updated(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)"),
            .init("UPDATE ddlcompat.ge_updated SET n=12,v='xyzx',d='2025-01-02' WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.ge_added(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,bucket INT AS (INTERVAL(n,1,5)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ge_added(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)"),
            .init("UPDATE ddlcompat.ge_added SET n=12,v='xyzx',d='2025-01-02' WHERE id=1"),
            .init(
                "ALTER TABLE ddlcompat.ge_added ADD absent INT AS (n IS NOT NULL) STORED,ADD bounded INT AS (n NOT BETWEEN 1 AND 10) STORED"
            ),
            .init(
                "CREATE TABLE ddlcompat.ge_predicates(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,bucket INT AS (INTERVAL(n,1,5)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ge_predicates(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)"),
            .init("UPDATE ddlcompat.ge_predicates SET n=12,v='xyzx',d='2025-01-02' WHERE id=1"),
            .init(
                "ALTER TABLE ddlcompat.ge_predicates ADD absent INT AS (n IS NOT NULL) STORED,ADD bounded INT AS (n NOT BETWEEN 1 AND 10) STORED"
            ),
            .init("UPDATE ddlcompat.ge_predicates SET n=1 WHERE id=2", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-expression-values",
                    check: .init(
                        "SELECT id,c,chosen,bits,head,clean,yr,great,member,missing FROM ddlcompat.ge_initial ORDER BY id",
                        "1\t3\t40\t6\txxa\tabc\t2026\t10\t1\t0\n2\t0\t0\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t1")),
                .init(
                    id: "initial-interval-values",
                    check: .init("SELECT id,bucket FROM ddlcompat.ge_initial ORDER BY id", "1\t1\n2\t-1")),
                .init(
                    id: "initial-date-binary-and-negation",
                    check: .init(
                        "SELECT id,tomorrow,HEX(raw),negated FROM ddlcompat.ge_initial ORDER BY id",
                        "1\t2026-10-15\t0102\t1\n2\tNULL\t0102\tNULL")),
                .init(
                    id: "updated-expression-values",
                    check: .init(
                        "SELECT c,chosen,bits,head,clean,yr,great,member FROM ddlcompat.ge_updated WHERE id=1",
                        "0\t0\t8\txyz\tyz\t2025\t12\t0")),
                .init(
                    id: "added-predicates-before-null-update",
                    check: .init("SELECT id,absent,bounded FROM ddlcompat.ge_added ORDER BY id", "1\t1\t1\n2\t0\tNULL")),
                .init(
                    id: "predicate-input-update",
                    check: .init(
                        "SELECT id,c,chosen,bits,great,member,missing,absent,bounded FROM ddlcompat.ge_predicates ORDER BY id",
                        "1\t0\t0\t8\t12\t0\t0\t1\t1\n2\t1\t20\t2\t10\t1\t0\t1\t0")),
                .init(
                    id: "like-copy-generated-values",
                    check: .init(
                        "SELECT id,n,chosen,tomorrow,HEX(raw),negated,bucket FROM ddlcompat.copy",
                        "3\t1\t20\t2024-01-02\t0102\t0\t1")),
                .init(
                    id: "final-row-after-delete",
                    check: .init(
                        "SELECT id,c,chosen,bits,great,member,missing,absent,bounded FROM ddlcompat.t",
                        "2\t1\t20\t2\t10\t1\t0\t1\t0")),
                .init(
                    id: "like-copy-generated-index",
                    check: .init(
                        "SELECT COLUMN_NAME,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy' AND INDEX_NAME='by_chosen' ORDER BY SEQ_IN_INDEX",
                        "chosen\tBTREE")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.ge_initial,ddlcompat.ge_updated,ddlcompat.ge_added,ddlcompat.ge_predicates"]
        ))
}
