import Foundation

extension DDLCompatibilityCases {
    static let primaryKeyParts = Case(
        "primary-key-parts", "Primary-key prefixes, complete-value lookups, ALTER, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.t(k VARBINARY(40),b BLOB,n INT,PRIMARY KEY(k(8),b(4)))"),
            .init("INSERT INTO ddlcompat.t VALUES('abcdefgh-first',X'0102030405',1),('ijklmnop-next',X'0506070809',2)"),
            .init("UPDATE ddlcompat.t SET k='abcdefgh-second',b=X'0102030406',n=3 WHERE n=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t DROP PRIMARY KEY,ADD PRIMARY KEY(k(10),b(5))"),
            .init("ALTER TABLE ddlcompat.t CHANGE k renamed VARBINARY(60)", restartBefore: true),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t"),
            .init("INSERT INTO ddlcompat.copy SELECT * FROM ddlcompat.t"),
            .init(
                "DELETE FROM ddlcompat.t WHERE n=2",
                [
                    .init(
                        "SELECT HEX(renamed),HEX(b),n FROM ddlcompat.t", "61626364656667682D7365636F6E64\t0102030406\t3"
                    )
                ], restartBefore: true),
            .init("ALTER TABLE ddlcompat.t RENAME ddlcompat.moved"),
            .init("UPDATE ddlcompat.moved SET n=4"),
            .init("DROP TABLE ddlcompat.moved,ddlcompat.copy"),
        ])
}
