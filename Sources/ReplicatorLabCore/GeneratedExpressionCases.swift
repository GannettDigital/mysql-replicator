import Foundation

extension DDLCompatibilityCases {
    static let generatedExpressions=Case("generated-expressions","CASE, predicates, bit operators and native functions retain generated values across DML and restart",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,v VARCHAR(30),d DATE,c INT AS (CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END) STORED,chosen INT AS (CASE n WHEN 1 THEN 20 WHEN 3 THEN 40 ELSE 0 END) STORED,bits INT AS ((n & 7) << 1) STORED,head VARCHAR(3) AS (SUBSTRING(v FROM 1 FOR 3)) STORED,clean VARCHAR(30) AS (TRIM(BOTH 'x' FROM v)) STORED,yr INT AS (EXTRACT(YEAR FROM d)) STORED,great INT AS (GREATEST(n,10)) STORED,member INT AS (n IN (1,3)) STORED,missing INT AS (n IS NULL) STORED,tomorrow DATE AS (DATE_ADD(d,INTERVAL 1 DAY)) STORED,raw VARBINARY(4) AS (X'0102') STORED,negated INT AS (NOT(n=1)) STORED,KEY by_chosen(chosen)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
        .init("INSERT INTO ddlcompat.t(id,n,v,d) VALUES(1,3,'xxabcx','2026-10-14'),(2,NULL,NULL,NULL)",[
            .init("SELECT id,c,chosen,bits,head,clean,yr,great,member,missing FROM ddlcompat.t ORDER BY id","1\t3\t40\t6\txxa\tabc\t2026\t10\t1\t0\n2\t0\t0\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t1")]),
        .init("UPDATE ddlcompat.t SET n=12,v='xyzx',d='2025-01-02' WHERE id=1",[
            .init("SELECT c,chosen,bits,head,clean,yr,great,member FROM ddlcompat.t WHERE id=1","0\t0\t8\txyz\tyz\t2025\t12\t0")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t ADD absent INT AS (n IS NOT NULL) STORED,ADD bounded INT AS (n NOT BETWEEN 1 AND 10) STORED"),
        .init("UPDATE ddlcompat.t SET n=1 WHERE id=2",[
            .init("SELECT id,c,chosen,bits,great,member,missing,absent,bounded FROM ddlcompat.t ORDER BY id","1\t0\t0\t8\t12\t0\t0\t1\t1\n2\t1\t20\t2\t10\t1\t0\t1\t0")]),
        .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
        .init("INSERT INTO ddlcompat.copy(id,n,v,d) VALUES(3,1,'xxone','2024-01-01')",restartBefore:true),
        .init("DELETE FROM ddlcompat.t WHERE id=1")
    ])
}
