import Foundation

extension DDLCompatibilityCases {
    static let partitionColumnBounds=Case("partition-column-bounds","Binary and charset bounds, native DATE spelling, tuple routing, restart and offline replay",[
        .init("CREATE TABLE ddlcompat.t(v VARBINARY(10) PRIMARY KEY,n INT) PARTITION BY RANGE COLUMNS(v)(PARTITION p VALUES LESS THAN(X'80FF'),PARTITION q VALUES LESS THAN(MAXVALUE))"),
        .init("INSERT INTO ddlcompat.t VALUES(X'0080',1),(X'80FE',2),(X'80FF',3),(X'FF',4)",[.init("SELECT HEX(v),n FROM ddlcompat.t PARTITION(p) ORDER BY v","0080\t1\n80FE\t2")]),
        .init("ALTER TABLE ddlcompat.t REORGANIZE PARTITION q INTO(PARTITION middle VALUES LESS THAN(_binary X'F0'),PARTITION q VALUES LESS THAN(MAXVALUE))"),
        .init("UPDATE ddlcompat.t SET v=X'81' WHERE v=X'80FE'",[.init("SELECT HEX(v),n FROM ddlcompat.t PARTITION(middle) ORDER BY v","80FF\t3\n81\t2")],restartBefore:true),
        .init("CREATE TABLE ddlcompat.s(v VARCHAR(10) CHARACTER SET latin1 COLLATE latin1_bin PRIMARY KEY,n INT) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN(_latin1 X'E9','a  '),PARTITION q VALUES IN('z'))"),
        .init("INSERT INTO ddlcompat.s VALUES(_latin1 X'E9',1),('a',2),('z',3)",[.init("SELECT HEX(v),n FROM ddlcompat.s PARTITION(p) ORDER BY v","61\t2\nE9\t1")]),
        .init("CREATE TABLE ddlcompat.d(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY RANGE COLUMNS(d,id)(PARTITION p VALUES LESS THAN('20260101',10),PARTITION q VALUES LESS THAN(MAXVALUE,MAXVALUE))"),
        .init("INSERT INTO ddlcompat.d VALUES('2026-01-01',9),('2026-01-01',10)",[.init("SELECT id FROM ddlcompat.d PARTITION(p)","9"),.init("SELECT id FROM ddlcompat.d PARTITION(q)","10")]),
        .init("DELETE FROM ddlcompat.t WHERE v=X'FF'",[.init("SELECT HEX(v),n FROM ddlcompat.t ORDER BY v","0080\t1\n80FF\t3\n81\t2")],restartBefore:true),
        .init("SET character_set_connection=latin1; CREATE TABLE ddlcompat.encoded(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN('é',_latin1 'é'))"),
        .init("INSERT INTO ddlcompat.encoded VALUES(X'E9'),(X'C3A9')",[.init("SELECT HEX(v) FROM ddlcompat.encoded ORDER BY v","C3A9\nE9")]),
        .init("CREATE TABLE ddlcompat.b(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN(X'005C0A27',X'FF',X'',X'2A2F'))"),
        .init("INSERT INTO ddlcompat.b VALUES(X'005C0A27'),(X'FF'),(X''),(X'2A2F')",[.init("SELECT LENGTH(v),HEX(v) FROM ddlcompat.b ORDER BY v","0\t\n4\t005C0A27\n2\t2A2F\n1\tFF")])
    ],nativeInnoDB:true)
}
