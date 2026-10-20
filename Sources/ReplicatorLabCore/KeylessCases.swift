import Foundation

extension DDLCompatibilityCases {
    static let keylessRows = Case(
        "keyless-rows",
        "Full-row matching preserves duplicates, NULLs, exact bytes and JSON types through restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(n INT NULL,s VARCHAR(20) COLLATE utf8mb4_unicode_ci,b BLOB,j JSON,g INT GENERATED ALWAYS AS (n+1) STORED,UNIQUE KEY nullable_n(n),KEY by_s(s(3)))"
            ),
            .init(
                "INSERT INTO ddlcompat.t(n,s,b,j) VALUES(NULL,'same',X'00FF',JSON_OBJECT('a',1)),(NULL,'same',X'00FF',JSON_OBJECT('a',1)),(NULL,'SAME',X'00FF',JSON_OBJECT('a',1)),(NULL,'same ',X'00FF',JSON_OBJECT('a',1)),(1,NULL,NULL,NULL)"
            ),
            .init(
                "UPDATE ddlcompat.t SET s='first' WHERE n IS NULL AND BINARY s='same' LIMIT 1",
                [.init("SELECT COUNT(*) FROM ddlcompat.t WHERE BINARY s='same'", "1")], restartBefore: true),
            .init(
                "DELETE FROM ddlcompat.t WHERE BINARY s='same' LIMIT 1",
                [.init("SELECT COUNT(*) FROM ddlcompat.t", "4")]),
            .init(
                "UPDATE ddlcompat.t SET n=2,b=X'FF00',j=JSON_ARRAY(NULL,JSON_OBJECT('b',2)) WHERE n=1",
                [.init("SELECT n,g,HEX(b) FROM ddlcompat.t WHERE n=2", "2\t3\tFF00")]),
            .init(
                "DELETE FROM ddlcompat.t WHERE BINARY s='same '",
                [.init("SELECT COUNT(*) FROM ddlcompat.t WHERE BINARY s='SAME'", "1")]),
            .init("INSERT INTO ddlcompat.t(n,s,b,j) VALUES(NULL,NULL,NULL,NULL),(NULL,NULL,NULL,NULL)"),
            .init(
                "UPDATE ddlcompat.t SET b=X'00' WHERE n IS NULL AND s IS NULL",
                [.init("SELECT COUNT(*) FROM ddlcompat.t WHERE b=X'00'", "2")], restartBefore: true),
            .init(
                "DELETE FROM ddlcompat.t WHERE b=X'00' LIMIT 1",
                [.init("SELECT COUNT(*) FROM ddlcompat.t WHERE b=X'00'", "1")]),
            .init("CREATE TABLE ddlcompat.docs(j JSON,v INT)"),
            .init(
                "INSERT INTO ddlcompat.docs VALUES(JSON_ARRAY(CAST(1.25 AS DECIMAL(4,2))),1),(JSON_ARRAY(1.25e0),1),(JSON_ARRAY('1.25'),1),(JSON_ARRAY(NULL),1),(NULL,1)"
            ),
            .init(
                "UPDATE ddlcompat.docs SET v=2 WHERE JSON_TYPE(JSON_EXTRACT(j,'$[0]'))='DECIMAL'",
                [.init("SELECT COUNT(*) FROM ddlcompat.docs WHERE v=2", "1")]),
            .init(
                "DELETE FROM ddlcompat.docs WHERE JSON_TYPE(JSON_EXTRACT(j,'$[0]'))='DOUBLE'",
                [.init("SELECT COUNT(*) FROM ddlcompat.docs", "4")], restartBefore: true),
            .init("UPDATE ddlcompat.docs SET v=3 WHERE j IS NULL"),
            .init("DELETE FROM ddlcompat.docs WHERE JSON_TYPE(JSON_EXTRACT(j,'$[0]'))='NULL'"),
            .init("ALTER TABLE ddlcompat.docs ADD PRIMARY KEY(v)"),
            .init("UPDATE ddlcompat.docs SET v=4 WHERE v=2"),
            .init("ALTER TABLE ddlcompat.docs DROP PRIMARY KEY"),
            .init("DELETE FROM ddlcompat.docs WHERE v=4"),
            .init(
                "CREATE TABLE ddlcompat.values_t(d DECIMAL(30,2),f FLOAT(5,2),e ENUM('a','b'),s SET('x','y'),bits BIT(8),p POINT,tm TIME(6),txt VARCHAR(20) CHARACTER SET latin1)"
            ),
            .init(
                "INSERT INTO ddlcompat.values_t VALUES(9007199254740992.25,999.99,'a','x,y',b'10101010',ST_GeomFromText('POINT(1 2)'),'-12:00:01.123456',CONVERT(X'E9' USING latin1)),(9007199254740993.25,999.99,'a','x,y',b'10101010',ST_GeomFromText('POINT(1 2)'),'-12:00:01.123456',CONVERT(X'E9' USING latin1))"
            ),
            .init(
                "UPDATE ddlcompat.values_t SET txt='changed' WHERE d=9007199254740993.25",
                [.init("SELECT d FROM ddlcompat.values_t WHERE txt='changed'", "9007199254740993.25")]),
            .init(
                "DELETE FROM ddlcompat.values_t WHERE d=9007199254740992.25",
                [.init("SELECT COUNT(*) FROM ddlcompat.values_t", "1")]),
            .init("CREATE TABLE ddlcompat.zeros(f FLOAT,d DOUBLE,v INT,j JSON)"),
            .init("INSERT INTO ddlcompat.zeros VALUES(0e0,0e0,1,JSON_ARRAY(0e0)),(-0e0,-0e0,1,JSON_ARRAY(-0e0))"),
            .init(
                "UPDATE ddlcompat.zeros SET v=2 WHERE ATAN2(f,-1)<0",
                [
                    .init(
                        "SELECT v,SIGN(ATAN2(f,-1)),SIGN(ATAN2(d,-1)) FROM ddlcompat.zeros ORDER BY v",
                        "1\t1\t1\n2\t-1\t-1")
                ]),
            .init("DELETE FROM ddlcompat.zeros WHERE ATAN2(d,-1)>=0", [.init("SELECT v FROM ddlcompat.zeros", "2")]),
        ])
}
