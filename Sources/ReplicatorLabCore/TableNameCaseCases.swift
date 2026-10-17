import Foundation

extension DDLCompatibilityCases {
    static let tableNameCase = Case(
        "table-name-case", "Native lowercase table names through DDL, row events and restart",
        [
            .init("CREATE TABLE ddlcompat.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO DDLCOMPAT.`mixé`(id) VALUES(1)", [.init("SELECT ID,n FROM ddlcompat.`MIXÉ`", "1\t7")]),
            .init("ALTER TABLE DDLCOMPAT.`MIXÉ` ADD extra INT DEFAULT 3", restartBefore: true),
            .init("UPDATE ddlcompat.`mixé` SET extra=9 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.`CoPy` LIKE DDLCOMPAT.`MIXÉ`"),
            .init("INSERT INTO ddlcompat.`COPY` SELECT * FROM ddlcompat.`mixé`"),
            .init("RENAME TABLE DDLCOMPAT.`COPY` TO ddlcompat.`Final`,ddlcompat.`MiXÉ` TO ddlcompat.`Old`"),
            .init(
                "UPDATE ddlcompat.`FINAL` SET n=8 WHERE id=1",
                [.init("SELECT ID,n,extra FROM ddlcompat.`final`", "1\t8\t9")], restartBefore: true),
            .init("DROP TABLE ddlcompat.`OLD`"),
            .init("DROP TABLE ddlcompat.`FINAL`"),
        ])
}
