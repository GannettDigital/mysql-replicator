import Foundation

extension DDLCompatibilityCases {
    static let tableOptions=Case("table-options","Table and column comments, row format and AUTO_INCREMENT with LIKE, row changes and restart",[
        .init("CREATE TABLE ddlcompat.t(id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,n VARCHAR(30) NOT NULL DEFAULT 'seed' COMMENT 'value note',b VARBINARY(8) NOT NULL DEFAULT X'00FF') COMMENT='table note' ROW_FORMAT=DYNAMIC AUTO_INCREMENT=100",[
            .init("SELECT TABLE_COMMENT,ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'","table note\tDynamic"),
            .init("SELECT COLUMN_COMMENT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='n'","value note"),
            .init("SELECT HEX(COLUMN_DEFAULT) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='n'","73656564")]),
        .init("INSERT INTO ddlcompat.t(n) VALUES('first')",[.init("SELECT id,n,HEX(b) FROM ddlcompat.t","100\tfirst\t00FF")]),
        .init("ALTER TABLE ddlcompat.t COMMENT='changed note' ROW_FORMAT=DYNAMIC, AUTO_INCREMENT=200",[
            .init("SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'","changed note")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t MODIFY n VARCHAR(40) COMMENT 'changed column'",[
            .init("SELECT COLUMN_COMMENT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='n'","changed column")]),
        .init("INSERT INTO ddlcompat.t(n) VALUES('second')",[.init("SELECT id,n FROM ddlcompat.t ORDER BY id","100\tfirst\n200\tsecond")]),
        .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t",[
            .init("SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy'","changed note")]),
        .init("INSERT INTO ddlcompat.copy(id,n) VALUES(1,'copy')",restartBefore:true),
        .init("UPDATE ddlcompat.t SET n='last' WHERE id=100"),
        .init("DELETE FROM ddlcompat.t WHERE id=200")
    ])
    static let alterConversions=Case("alter-conversions","Native column conversions preserve rows, defaults, indexes and saved schemas",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
        .init("INSERT INTO ddlcompat.t VALUES(1,12),(2,34)"),
        .init("ALTER TABLE ddlcompat.t MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'",[.init("SELECT id,n FROM ddlcompat.t ORDER BY id","1\t12\n2\t34")]),
        .init("UPDATE ddlcompat.t SET n='56' WHERE id=1",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50",[.init("SELECT id,amount FROM ddlcompat.t FORCE INDEX(by_n) ORDER BY id","1\t56.00\n2\t34.00")]),
        .init("INSERT INTO ddlcompat.t(id) VALUES(3)",[.init("SELECT amount FROM ddlcompat.t WHERE id=3","3.50")]),
        .init("ALTER TABLE ddlcompat.t MODIFY amount DOUBLE NOT NULL DEFAULT 4"),
        .init("UPDATE ddlcompat.t SET amount=78 WHERE id=2",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 4"),
        .init("DELETE FROM ddlcompat.t WHERE id=3"),
        .init("ALTER TABLE ddlcompat.t MODIFY amount BIT(8) NOT NULL DEFAULT b'00000100'",[.init("SELECT id,amount+0 FROM ddlcompat.t ORDER BY id","1\t56\n2\t78")]),
        .init("UPDATE ddlcompat.t SET amount=b'01100100' WHERE id=1",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 5"),
        .init("INSERT INTO ddlcompat.t(id) VALUES(4)",[.init("SELECT id,amount FROM ddlcompat.t ORDER BY id","1\t100\n2\t78\n4\t5")])
    ])
}
