import Foundation

extension DDLCompatibilityCases {
    static let taggedGTIDs=Case("tagged-gtids","Tagged DDL and DML retain independent counters through rotation, restart and replay",[
        .init("SET GTID_NEXT='AUTOMATIC:blue'; CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
        .init("SET GTID_NEXT='AUTOMATIC:green'; INSERT INTO ddlcompat.t VALUES(1,10)"),
        .init("SET GTID_NEXT='AUTOMATIC:blue'; INSERT INTO ddlcompat.t VALUES(2,20)",restartBefore:true),
        .init("FLUSH BINARY LOGS; SET GTID_NEXT='AUTOMATIC:green'; ALTER TABLE ddlcompat.t ADD extra INT DEFAULT 7"),
        .init("INSERT INTO ddlcompat.t(id,n) VALUES(3,30)",restartBefore:true),
        .init("SET GTID_NEXT='AUTOMATIC:blue'; UPDATE ddlcompat.t SET n=21 WHERE id=2"),
        .init("SET GTID_NEXT='AUTOMATIC:green'; DELETE FROM ddlcompat.t WHERE id=1",[.init("SELECT id,n,extra FROM ddlcompat.t ORDER BY id","2\t21\t7\n3\t30\t7")])
    ],profileExclusions:[.reverse:"Tagged GTIDs require an 8.4 source.",.mysql57MyISAM:"Tagged GTIDs require an 8.4 source.",.mysql57InnoDB:"Tagged GTIDs require an 8.4 source."])
}

extension DDLCompatibilityCases {
    static let preservedGTIDs=Case("source-gtid-preservation","Source GTIDs remain on target after ordered multi-row writes, restart and replay",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,j JSON)"),
        .init("INSERT INTO ddlcompat.t VALUES "+(1...40).map {"(\($0),\($0),JSON_OBJECT('n',\($0)))"}.joined(separator:",")),
        .init("UPDATE ddlcompat.t SET n=n+10,j=JSON_SET(j,'$.n',n)",[.init("SELECT COUNT(*),SUM(n) FROM ddlcompat.t","40\t1220")],restartBefore:true),
        .init("DELETE FROM ddlcompat.t WHERE id>30",[.init("SELECT COUNT(*) FROM ddlcompat.t","30")]),
        .init("CREATE TABLE ddlcompat.k(n INT,s VARCHAR(20))"),
        .init("INSERT INTO ddlcompat.k VALUES(NULL,NULL),(NULL,NULL),(1,'a')"),
        .init("UPDATE ddlcompat.k SET n=2,s='b' WHERE n IS NULL",[.init("SELECT n,s FROM ddlcompat.k ORDER BY n","1\ta\n2\tb\n2\tb")]),
        .init("DELETE FROM ddlcompat.k WHERE n=2",[.init("SELECT COUNT(*) FROM ddlcompat.k","1")])
    ])
}
