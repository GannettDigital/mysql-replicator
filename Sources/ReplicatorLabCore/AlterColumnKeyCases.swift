import Foundation

extension DDLCompatibilityCases {
    static let alterColumnKeys=Case("alter-column-keys","Inline primary keys, AUTO_INCREMENT additions, implicit rebuild values, restart and replay",[
        .init("CREATE TABLE ddlcompat.t(v INT)"),
        .init("INSERT INTO ddlcompat.t VALUES(7)"),
        .init("ALTER TABLE ddlcompat.t ADD id INT PRIMARY KEY FIRST",[
            .init("SELECT id,v FROM ddlcompat.t","0\t7")]),
        .init("UPDATE ddlcompat.t SET id=1,v=8 WHERE id=0",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL",[
            .init("SELECT id,v,n,CONCAT('[',s,']') FROM ddlcompat.t","1\t8\t0\t[]"),
            .init("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME IN('n','s') AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL","2")]),
        .init("ALTER TABLE ddlcompat.t MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
        .init("ALTER TABLE ddlcompat.t CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
        .init("UPDATE ddlcompat.t SET k=2,n=9,s='x' WHERE k=1",[
            .init("SELECT k,v,n,s FROM ddlcompat.t","2\t8\t9\tx")],restartBefore:true),
        .init("SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER TABLE ddlcompat.t ADD aid INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,DROP PRIMARY KEY,ALGORITHM=COPY",[
            .init("SELECT aid,k,v FROM ddlcompat.t","2\t2\t8")]),
        .init("INSERT INTO ddlcompat.t(k,v,n,s) VALUES(3,10,11,'y')",[
            .init("SELECT aid,k FROM ddlcompat.t ORDER BY aid","2\t2\n5\t3")]),
        .init("UPDATE ddlcompat.t SET v=12 WHERE aid=5",restartBefore:true),
        .init("DELETE FROM ddlcompat.t WHERE aid=2"),
        .init("CREATE TABLE ddlcompat.e(v INT)"),
        .init("ALTER TABLE ddlcompat.e ADD id BIGINT AUTO_INCREMENT PRIMARY KEY FIRST"),
        .init("INSERT INTO ddlcompat.e(v) VALUES(20),(30)",[
            .init("SELECT id,v FROM ddlcompat.e ORDER BY id","1\t20\n2\t30")],restartBefore:true),
        .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,v INT)"),
        .init("INSERT INTO ddlcompat.u VALUES(1,10),(2,20)"),
        .init("ALTER TABLE ddlcompat.u ADD KEY by_seq(seq),ADD seq INT NOT NULL AUTO_INCREMENT",[
            .init("SELECT id,seq FROM ddlcompat.u ORDER BY id","1\t1\n2\t2")]),
        .init("ALTER TABLE ddlcompat.u ADD PRIMARY KEY(seq),DROP PRIMARY KEY,DROP INDEX by_seq"),
        .init("UPDATE ddlcompat.u SET v=21 WHERE seq=2",restartBefore:true),
        .init("DELETE FROM ddlcompat.u WHERE seq=1"),
        .init("CREATE TABLE ddlcompat.c(v INT)"),
        .init("ALTER TABLE ddlcompat.c ADD PRIMARY KEY(id),ADD id INT NOT NULL AUTO_INCREMENT"),
        .init("INSERT INTO ddlcompat.c(v) VALUES(40)",[.init("SELECT id,v FROM ddlcompat.c","1\t40")],restartBefore:true),
        .init("DROP TABLE ddlcompat.t,ddlcompat.e,ddlcompat.u,ddlcompat.c")
    ])
}
