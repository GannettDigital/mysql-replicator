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
        "alter-conversions", "ALTER TABLE: convert existing indexed column values",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.t MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'", phaseEnd: "convert-to-varchar"),
            .init("UPDATE ddlcompat.t SET n='56' WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50"),
            .init("INSERT INTO ddlcompat.t(id) VALUES(3)"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY amount DOUBLE NOT NULL DEFAULT 4",
                phaseEnd: "rename-and-convert-to-double"),
            .init("UPDATE ddlcompat.t SET amount=78 WHERE id=2", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 4"),
            .init("DELETE FROM ddlcompat.t WHERE id=3"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY amount BIT(8) NOT NULL DEFAULT b'00000100'",
                phaseEnd: "convert-to-integer-and-bit"),
            .init("UPDATE ddlcompat.t SET amount=b'01100100' WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY amount INT NOT NULL DEFAULT 5"),
            .init("INSERT INTO ddlcompat.t(id) VALUES(4)"),
            .init(
                "CREATE TABLE ddlcompat.cv_initial(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_initial VALUES(1,12),(2,34)"),
            .init(
                "CREATE TABLE ddlcompat.cv_varchar(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_varchar VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.cv_varchar MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'"),
            .init(
                "CREATE TABLE ddlcompat.cv_decimal(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_decimal VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.cv_decimal MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'"),
            .init("UPDATE ddlcompat.cv_decimal SET n='56' WHERE id=1"),
            .init("ALTER TABLE ddlcompat.cv_decimal CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50"),
            .init("INSERT INTO ddlcompat.cv_decimal(id) VALUES(3)"),
            .init(
                "CREATE TABLE ddlcompat.cv_double(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_double VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.cv_double MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'"),
            .init("UPDATE ddlcompat.cv_double SET n='56' WHERE id=1"),
            .init("ALTER TABLE ddlcompat.cv_double CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50"),
            .init("INSERT INTO ddlcompat.cv_double(id) VALUES(3)"),
            .init("ALTER TABLE ddlcompat.cv_double MODIFY amount DOUBLE NOT NULL DEFAULT 4"),
            .init("UPDATE ddlcompat.cv_double SET amount=78 WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.cv_integer(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_integer VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.cv_integer MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'"),
            .init("UPDATE ddlcompat.cv_integer SET n='56' WHERE id=1"),
            .init("ALTER TABLE ddlcompat.cv_integer CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50"),
            .init("INSERT INTO ddlcompat.cv_integer(id) VALUES(3)"),
            .init("ALTER TABLE ddlcompat.cv_integer MODIFY amount DOUBLE NOT NULL DEFAULT 4"),
            .init("UPDATE ddlcompat.cv_integer SET amount=78 WHERE id=2"),
            .init("ALTER TABLE ddlcompat.cv_integer MODIFY amount INT NOT NULL DEFAULT 4"),
            .init(
                "CREATE TABLE ddlcompat.cv_bit(id INT PRIMARY KEY,n INT NOT NULL DEFAULT 7,KEY by_n(n)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.cv_bit VALUES(1,12),(2,34)"),
            .init("ALTER TABLE ddlcompat.cv_bit MODIFY n VARCHAR(30) NOT NULL DEFAULT '9'"),
            .init("UPDATE ddlcompat.cv_bit SET n='56' WHERE id=1"),
            .init("ALTER TABLE ddlcompat.cv_bit CHANGE n amount DECIMAL(10,2) NOT NULL DEFAULT 3.50"),
            .init("INSERT INTO ddlcompat.cv_bit(id) VALUES(3)"),
            .init("ALTER TABLE ddlcompat.cv_bit MODIFY amount DOUBLE NOT NULL DEFAULT 4"),
            .init("UPDATE ddlcompat.cv_bit SET amount=78 WHERE id=2"),
            .init("ALTER TABLE ddlcompat.cv_bit MODIFY amount INT NOT NULL DEFAULT 4"),
            .init("DELETE FROM ddlcompat.cv_bit WHERE id=3"),
            .init(
                "ALTER TABLE ddlcompat.cv_bit MODIFY amount BIT(8) NOT NULL DEFAULT b'00000100'",
                phaseEnd: "convert-back-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-integer-values",
                    check: .init("SELECT id,n FROM ddlcompat.cv_initial ORDER BY id", "1\t12\n2\t34")),
                .init(
                    id: "converted-varchar-values",
                    check: .init("SELECT id,n FROM ddlcompat.cv_varchar ORDER BY id", "1\t12\n2\t34")),
                .init(
                    id: "converted-decimal-index-values",
                    check: .init(
                        "SELECT id,amount FROM ddlcompat.cv_decimal FORCE INDEX(by_n) WHERE id IN (1,2) ORDER BY id",
                        "1\t56.00\n2\t34.00")),
                .init(
                    id: "decimal-default-insert",
                    check: .init("SELECT amount FROM ddlcompat.cv_decimal WHERE id=3", "3.50")),
                .init(
                    id: "double-update-and-fractional-row",
                    check: .init("SELECT id,amount FROM ddlcompat.cv_double ORDER BY id", "1\t56\n2\t78\n3\t3.5")),
                .init(
                    id: "fractional-row-retained-after-integer-conversion",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.cv_integer WHERE id=3", "1")),
                .init(
                    id: "bit-values-after-delete",
                    check: .init("SELECT id,amount+0 FROM ddlcompat.cv_bit ORDER BY id", "1\t56\n2\t78")),
                .init(
                    id: "bit-definition",
                    check: .init(
                        "SELECT COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NOT NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cv_bit' AND COLUMN_NAME='amount'",
                        "bit(8)\tNO\t1")),
                .init(
                    id: "final-integer-values-and-default",
                    check: .init("SELECT id,amount FROM ddlcompat.t ORDER BY id", "1\t100\n2\t78\n4\t5")),
                .init(
                    id: "conversion-types-and-defaults",
                    check: .init(
                        "SELECT TABLE_NAME,DATA_TYPE,COLUMN_DEFAULT,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('cv_initial','cv_varchar','cv_decimal','cv_double','cv_integer','t') AND COLUMN_NAME IN ('n','amount') ORDER BY BINARY TABLE_NAME",
                        "cv_decimal\tdecimal\t3.50\tNO\ncv_double\tdouble\t4\tNO\ncv_initial\tint\t7\tNO\ncv_integer\tint\t4\tNO\ncv_varchar\tvarchar\t9\tNO\nt\tint\t5\tNO"
                    )),
                .init(
                    id: "index-column-through-conversions",
                    check: .init(
                        "SELECT TABLE_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND INDEX_NAME='by_n' ORDER BY BINARY TABLE_NAME",
                        "cv_bit\tamount\ncv_decimal\tamount\ncv_double\tamount\ncv_initial\tn\ncv_integer\tamount\ncv_varchar\tn\nt\tamount"
                    )),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.cv_initial,ddlcompat.cv_varchar,ddlcompat.cv_decimal,ddlcompat.cv_double,ddlcompat.cv_integer,ddlcompat.cv_bit"
            ]))

}
