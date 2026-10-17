import Foundation

extension DDLCompatibilityCases {
    static let uniqueRowIdentity=Case("unique-row-identity","Unique-key row matching, key changes, DDL key replacement, restart and replay",[
        .init("CREATE TABLE ddlcompat.t(report_date DATE NOT NULL,id INT NOT NULL,code VARCHAR(20) COLLATE utf8mb4_unicode_ci NOT NULL,payload VARCHAR(40),UNIQUE KEY z_id(id),UNIQUE KEY a_report(report_date,id),UNIQUE KEY u_code(code))"),
        .init("INSERT INTO ddlcompat.t VALUES('2026-10-15',1,'alpha','one'),('2026-10-15',2,'beta',NULL)"),
        .init("UPDATE ddlcompat.t SET report_date='2026-10-16',id=3,payload='three' WHERE id=2",[.init("SELECT report_date,id,payload FROM ddlcompat.t WHERE id=3","2026-10-16\t3\tthree")],restartBefore:true),
        .init("DELETE FROM ddlcompat.t WHERE id=1",[.init("SELECT COUNT(*) FROM ddlcompat.t","1")]),
        .init("ALTER TABLE ddlcompat.t DROP INDEX a_report,ADD UNIQUE KEY b_report(report_date,id)"),
        .init("UPDATE ddlcompat.t SET payload='new index' WHERE id=3"),
        .init("ALTER TABLE ddlcompat.t DROP INDEX b_report,DROP INDEX z_id"),
        .init("UPDATE ddlcompat.t SET code='gamma' WHERE code='beta'",[.init("SELECT code FROM ddlcompat.t","gamma")],restartBefore:true),
        .init("UPDATE ddlcompat.t SET code='GAMMA' WHERE code='gamma'",[.init("SELECT HEX(code) FROM ddlcompat.t","47414D4D41")]),
        .init("ALTER TABLE ddlcompat.t ADD PRIMARY KEY(id)"),
        .init("UPDATE ddlcompat.t SET id=4 WHERE id=3"),
        .init("ALTER TABLE ddlcompat.t DROP PRIMARY KEY"),
        .init("ALTER TABLE ddlcompat.t RENAME INDEX u_code TO by_code"),
        .init("INSERT INTO ddlcompat.t VALUES('2026-10-16',5,'delta',NULL)"),
        .init("DELETE FROM ddlcompat.t WHERE code='GAMMA'",[.init("SELECT id,code FROM ddlcompat.t","5\tdelta")],restartBefore:true),
        .init("CREATE TABLE ddlcompat.seq(id INT NOT NULL AUTO_INCREMENT,payload INT,UNIQUE KEY by_id(id))"),
        .init("INSERT INTO ddlcompat.seq(payload) VALUES(10),(20)",[.init("SELECT id,payload FROM ddlcompat.seq ORDER BY id","1\t10\n2\t20")]),
        .init("UPDATE ddlcompat.seq SET id=3,payload=30 WHERE id=2",[.init("SELECT id,payload FROM ddlcompat.seq ORDER BY id","1\t10\n3\t30")]),
        .init("DELETE FROM ddlcompat.seq WHERE id=1",[.init("SELECT id,payload FROM ddlcompat.seq","3\t30")])
    ])
}
