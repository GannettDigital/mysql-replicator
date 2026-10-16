import Foundation

extension DDLCompatibilityCases {
    static let groupedConstraints=Case("grouped-constraints","Grouped FK and ignored CHECK clauses, reserved index names, restart and replay",[
        .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY)"),
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY)"),
        .init("ALTER TABLE ddlcompat.t ADD (a INT,CONSTRAINT uq UNIQUE(a),CONSTRAINT ignored CHECK(a>100))",sqlTransactional:"ALTER TABLE ddlcompat.t ADD (a INT,CONSTRAINT fk FOREIGN KEY(a) REFERENCES ddlcompat.p(id) ON UPDATE CASCADE,CONSTRAINT uq UNIQUE(a),CONSTRAINT ignored CHECK(a>100))"),
        .init("INSERT INTO ddlcompat.p VALUES(1)"),
        .init("INSERT INTO ddlcompat.t VALUES(1,1)",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t ADD (CHECK(a>100),CONSTRAINT ignored2 CHECK(a<0))"),
        .init("ALTER TABLE ddlcompat.t ADD (CHECK(a>100),b INT DEFAULT 5,CHECK(b<0)),ADD (KEY by_b(b))",restartBefore:true),
        .init("UPDATE ddlcompat.t SET b=6 WHERE id=1",[.init("SELECT id,a,b FROM ddlcompat.t","1\t1\t6")]),
        .init("CREATE TABLE ddlcompat.g(id INT PRIMARY KEY,`PRIMARY` INT,KEY(`PRIMARY`),KEY(`PRIMARY`))",[.init("SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='g' ORDER BY BINARY INDEX_NAME","PRIMARY\nPRIMARY_2\nPRIMARY_3")]),
        .init("INSERT INTO ddlcompat.g VALUES(1,2)"),
        .init("ALTER TABLE ddlcompat.g DROP KEY PRIMARY_2",restartBefore:true),
        .init("DELETE FROM ddlcompat.t"),
        .init("DROP TABLE ddlcompat.t,ddlcompat.p,ddlcompat.g")
    ],profileExclusions:[.forward:"An 8.4 CHECK is enforced; this case tests native 5.7 ignored CHECK clauses."])
}
