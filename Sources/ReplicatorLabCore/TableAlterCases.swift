import Foundation

extension DDLCompatibilityCases {
    static let tableOptions = Case(
        "table-options", "Table options: comments, row format, AUTO_INCREMENT and CREATE TABLE LIKE",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,n VARCHAR(30) NOT NULL DEFAULT 'seed' COMMENT 'value note',b VARBINARY(8) NOT NULL DEFAULT X'00FF') COMMENT='table note' ROW_FORMAT=DYNAMIC AUTO_INCREMENT=100"
            ),
            .init("INSERT INTO ddlcompat.t(n) VALUES('first')", phaseEnd: "prepare-original-options"),
            .init(
                "ALTER TABLE ddlcompat.t COMMENT='changed note' ROW_FORMAT=DYNAMIC, AUTO_INCREMENT=200",
                restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY n VARCHAR(40) COMMENT 'changed column'"),
            .init("INSERT INTO ddlcompat.t(n) VALUES('second')"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t", phaseEnd: "alter-options-and-copy"),
            .init("INSERT INTO ddlcompat.copy(id,n) VALUES(1,'copy')", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n='last' WHERE id=100"),
            .init("DELETE FROM ddlcompat.t WHERE id=200"),
            .init(
                "CREATE TABLE ddlcompat.to_initial(id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,n VARCHAR(30) NOT NULL DEFAULT 'seed' COMMENT 'value note',b VARBINARY(8) NOT NULL DEFAULT X'00FF') COMMENT='table note' ROW_FORMAT=DYNAMIC AUTO_INCREMENT=100"
            ),
            .init("INSERT INTO ddlcompat.to_initial(n) VALUES('first')"),
            .init(
                "CREATE TABLE ddlcompat.to_changed(id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,n VARCHAR(30) NOT NULL DEFAULT 'seed' COMMENT 'value note',b VARBINARY(8) NOT NULL DEFAULT X'00FF') COMMENT='table note' ROW_FORMAT=DYNAMIC AUTO_INCREMENT=100"
            ),
            .init("INSERT INTO ddlcompat.to_changed(n) VALUES('first')"),
            .init("ALTER TABLE ddlcompat.to_changed COMMENT='changed note' ROW_FORMAT=DYNAMIC, AUTO_INCREMENT=200"),
            .init("ALTER TABLE ddlcompat.to_changed MODIFY n VARCHAR(40) COMMENT 'changed column'"),
            .init("INSERT INTO ddlcompat.to_changed(n) VALUES('second')", phaseEnd: "write-and-retain-options"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-table-options",
                    check: .init(
                        "SELECT TABLE_COMMENT,ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='to_initial'",
                        "table note\tDynamic")),
                .init(
                    id: "initial-column-comment-and-default",
                    check: .init(
                        "SELECT COLUMN_COMMENT,HEX(COLUMN_DEFAULT) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='to_initial' AND COLUMN_NAME='n'",
                        "value note\t73656564")),
                .init(
                    id: "initial-generated-id-and-binary-default",
                    check: .init("SELECT id,n,HEX(b) FROM ddlcompat.to_initial", "100\tfirst\t00FF")),
                .init(
                    id: "changed-table-options",
                    check: .init(
                        "SELECT TABLE_COMMENT,ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='to_changed'",
                        "changed note\tDynamic")),
                .init(
                    id: "changed-column-definition",
                    check: .init(
                        "SELECT COLUMN_COMMENT,CHARACTER_MAXIMUM_LENGTH,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='to_changed' AND COLUMN_NAME='n'",
                        "changed column\t40\tYES\t1")),
                .init(
                    id: "generated-ids-before-update-delete",
                    check: .init(
                        "SELECT id,n,HEX(b) FROM ddlcompat.to_changed ORDER BY id",
                        "100\tfirst\t00FF\n200\tsecond\t00FF")),
                .init(
                    id: "like-copied-table-options",
                    check: .init(
                        "SELECT TABLE_COMMENT,ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy'",
                        "changed note\tDynamic")),
                .init(
                    id: "like-copied-column-comment",
                    check: .init(
                        "SELECT COLUMN_COMMENT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy' AND COLUMN_NAME='n'",
                        "changed column")),
                .init(id: "like-copy-insert", check: .init("SELECT id,n,HEX(b) FROM ddlcompat.copy", "1\tcopy\t00FF")),
                .init(id: "update-and-delete", check: .init("SELECT id,n,HEX(b) FROM ddlcompat.t", "100\tlast\t00FF")),
            ], databases: ["ddlcompat"], cleanup: ["DROP TABLE ddlcompat.to_initial,ddlcompat.to_changed"]))
    static let alterConversions = Case(
        "alter-conversions", "Native column conversions preserve rows, defaults, indexes and saved schemas",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,12),(2,34)"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'",
                [.init("SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t12\n2\t34")]),
            .init("UPDATE ddlcompat.t SET n='56' WHERE id=1", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50",
                [.init("SELECT id,amount FROM ddlcompat.t FORCE INDEX(by_n) ORDER BY id", "1\t56.00\n2\t34.00")]),
            .init(
                "INSERT INTO ddlcompat.t(id) VALUES(3)", [.init("SELECT amount FROM ddlcompat.t WHERE id=3", "3.50")]),
            .init("ALTER TABLE ddlcompat.t MODIFY amount DOUBLE NOT NULL DEFAULT 4"),
            .init("UPDATE ddlcompat.t SET amount=78 WHERE id=2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 4"),
            .init("DELETE FROM ddlcompat.t WHERE id=3"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY amount BIT(8) NOT NULL DEFAULT b'00000100'",
                [.init("SELECT id,amount+0 FROM ddlcompat.t ORDER BY id", "1\t56\n2\t78")]),
            .init("UPDATE ddlcompat.t SET amount=b'01100100' WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 5"),
            .init(
                "INSERT INTO ddlcompat.t(id) VALUES(4)",
                [.init("SELECT id,amount FROM ddlcompat.t ORDER BY id", "1\t100\n2\t78\n4\t5")]),
        ])
}
