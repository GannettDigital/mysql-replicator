import Foundation

extension DDLCompatibilityCases {
    static let primaryKeyRowMatching = Case(
        "primary-key-row-matching", "Composite and text PRIMARY KEY changes and row matching",
        [
            .init(
                "CREATE TABLE ddlcompat.composite_key(id INT NOT NULL,report_date DATE NOT NULL,v VARCHAR(40),PRIMARY KEY(report_date,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                assertionID: "composite-primary-key-create"),
            .init(
                "INSERT INTO ddlcompat.composite_key VALUES(7,'2026-01-01','a'),(7,'2026-01-02','b'),(8,'2026-01-01','c')",
                [
                    .init(
                        "SELECT report_date,id,v FROM ddlcompat.composite_key ORDER BY report_date,id",
                        "2026-01-01\t7\ta\n2026-01-01\t8\tc\n2026-01-02\t7\tb")
                ],
                assertionID: "composite-primary-key-insert"),
            .init(
                "UPDATE ddlcompat.composite_key SET report_date='2026-01-03',v='moved-date' WHERE report_date='2026-01-01' AND id=7",
                [
                    .init(
                        "SELECT report_date,id,v FROM ddlcompat.composite_key ORDER BY report_date,id",
                        "2026-01-01\t8\tc\n2026-01-02\t7\tb\n2026-01-03\t7\tmoved-date")
                ],
                assertionID: "composite-primary-key-update-date"),
            .init(
                "UPDATE ddlcompat.composite_key SET id=9,v='moved-id' WHERE report_date='2026-01-02' AND id=7",
                [
                    .init(
                        "SELECT report_date,id,v FROM ddlcompat.composite_key ORDER BY report_date,id",
                        "2026-01-01\t8\tc\n2026-01-02\t9\tmoved-id\n2026-01-03\t7\tmoved-date")
                ],
                assertionID: "composite-primary-key-update-id"),
            .init(
                "DELETE FROM ddlcompat.composite_key WHERE report_date='2026-01-01' AND id=8",
                [
                    .init(
                        "SELECT report_date,id,v FROM ddlcompat.composite_key ORDER BY report_date,id",
                        "2026-01-02\t9\tmoved-id\n2026-01-03\t7\tmoved-date")
                ],
                assertionID: "composite-primary-key-delete"),
            .init(
                "CREATE TABLE ddlcompat.text_key(id VARCHAR(20) COLLATE utf8mb4_unicode_ci PRIMARY KEY,v INT) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                assertionID: "text-primary-key-create"),
            .init(
                "INSERT INTO ddlcompat.text_key VALUES('Key',1),('other',2)",
                [.init("SELECT HEX(id),v FROM ddlcompat.text_key ORDER BY id", "4B6579\t1\n6F74686572\t2")],
                assertionID: "text-primary-key-insert"),
            .init(
                "UPDATE ddlcompat.text_key SET id='KEY',v=3 WHERE id='Key'",
                [.init("SELECT HEX(id),v FROM ddlcompat.text_key ORDER BY id", "4B4559\t3\n6F74686572\t2")],
                assertionID: "text-primary-key-update-case"),
            .init(
                "DELETE FROM ddlcompat.text_key WHERE id='key'",
                [.init("SELECT HEX(id),v FROM ddlcompat.text_key ORDER BY id", "6F74686572\t2")],
                assertionID: "text-primary-key-delete-case-insensitive"),
        ])

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
