import Foundation

extension DDLCompatibilityCases {
    static let generatedDependencies=Case("generated-dependencies","Generated dependency replacement, rename, stored/base conversion, restart and replay",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"),
        .init("INSERT INTO ddlcompat.t(id,a) VALUES(1,5)"),
        .init("ALTER TABLE ddlcompat.t CHANGE a b INT,MODIFY g INT AS(b+2) STORED",[
            .init("SELECT b,g,h,literal_text FROM ddlcompat.t","5\t7\t14\t`a`")]),
        .init("UPDATE ddlcompat.t SET b=6 WHERE id=1",[.init("SELECT g,h FROM ddlcompat.t","8\t16")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t MODIFY g INT AS(c+3) STORED,CHANGE b c INT",[
            .init("SELECT c,g,h FROM ddlcompat.t","6\t9\t18")]),
        .init("ALTER TABLE ddlcompat.t CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
        .init("UPDATE ddlcompat.t SET c=7 WHERE id=1",[.init("SELECT new_g,h FROM ddlcompat.t","10\t30")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED",[
            .init("SELECT d,new_g FROM ddlcompat.t","7\t11")]),
        .init("ALTER TABLE ddlcompat.t MODIFY new_g INT",[.init("SELECT new_g FROM ddlcompat.t","11")]),
        .init("UPDATE ddlcompat.t SET new_g=12 WHERE id=1",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t MODIFY d INT AS(id+3) STORED",[.init("SELECT d,new_g FROM ddlcompat.t","4\t12")]),
        .init("UPDATE ddlcompat.t SET id=2 WHERE id=1",[.init("SELECT d,new_g FROM ddlcompat.t","5\t12")],restartBefore:true),
        .init("CREATE TABLE ddlcompat.q(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
        .init("INSERT INTO ddlcompat.q(id,a) VALUES(1,8)"),
        .init("ALTER TABLE ddlcompat.q CHANGE a b INT,DROP g",[.init("SELECT id,b FROM ddlcompat.q","1\t8")]),
        .init("ALTER TABLE ddlcompat.q ADD g INT AS(b*2) STORED"),
        .init("ALTER TABLE ddlcompat.q DROP g,CHANGE b c INT"),
        .init("UPDATE ddlcompat.q SET c=9 WHERE id=1",restartBefore:true),
        .init("CREATE TABLE ddlcompat.l(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
        .init("INSERT INTO ddlcompat.l(id,a) VALUES(1,10)"),
        .init("ALTER TABLE ddlcompat.l CHANGE a b INT",[.init("SELECT b,g FROM ddlcompat.l","10\t`a`")]),
        .init("DELETE FROM ddlcompat.l WHERE id=1",restartBefore:true),
        .init("DROP TABLE ddlcompat.t,ddlcompat.q,ddlcompat.l")
    ])
}
