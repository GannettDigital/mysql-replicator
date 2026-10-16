import Foundation

extension DDLCompatibilityCases {
    static let tableMaintenance=Case("table-maintenance","FORCE and ENABLE/DISABLE KEYS retain rows and native index behavior across restart",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v INT,doubled INT AS(v*2) STORED,KEY by_v(v))"),
        .init("INSERT INTO ddlcompat.t(id,v) VALUES(1,10),(2,20)"),
        .init("ALTER TABLE ddlcompat.t DISABLE KEYS",[
            .init("SHOW INDEX FROM ddlcompat.t WHERE Key_name='by_v'","by_v\tBTREE\t",fields:[2,10,11],myISAMExpected:"by_v\tBTREE\tdisabled")]),
        .init("INSERT INTO ddlcompat.t(id,v) VALUES(3,30)",restartBefore:true),
        .init("UPDATE ddlcompat.t SET v=11 WHERE id=1"),
        .init("DELETE FROM ddlcompat.t WHERE id=2"),
        .init("ALTER TABLE ddlcompat.t ENABLE KEYS",[
            .init("SELECT COUNT(*) FROM ddlcompat.t FORCE INDEX(by_v) WHERE v>=11","2"),
            .init("SHOW INDEX FROM ddlcompat.t WHERE Key_name='by_v'","by_v\tBTREE\t",fields:[2,10,11])]),
        .init("ALTER TABLE ddlcompat.t FORCE",[
            .init("SELECT id,v,doubled FROM ddlcompat.t ORDER BY id","1\t11\t22\n3\t30\t60")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t FORCE, ADD note INT DEFAULT 7"),
        .init("DELETE FROM ddlcompat.t WHERE id=3",restartBefore:true)
    ])
}
