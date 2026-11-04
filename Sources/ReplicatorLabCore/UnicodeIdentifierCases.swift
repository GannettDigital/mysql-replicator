import Foundation

extension DMLCompatibilityCases {
    static let unicodeIdentifiers: Case = {
        let long = String(repeating: "中", count: 64)
        return Case(
            id: "unicodeidentifiers",
            definition:
                "id INT PRIMARY KEY,`é` INT DEFAULT 10,`e\u{0301}` INT DEFAULT 20,值 INT,`a``b` INT,`\(long)` INT,KEY `é`(`é`,id),KEY `e\u{0301}`(`e\u{0301}`,id)",
            phases: [
                .init(
                    sql:
                        "INSERT INTO poc.matrix_unicodeidentifiers(id,值,`a``b`,`\(long)`) VALUES(1,30,40,50),(2,NULL,NULL,NULL)",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=10 AND `e\u{0301}`=20 AND 值=30 AND `a``b`=40 AND `\(long)`=50"
                ),
                .init(
                    sql:
                        "UPDATE poc.matrix_unicodeidentifiers SET `É`=11,`e\u{0301}`=21,值=31 WHERE id=1; ALTER TABLE poc.matrix_unicodeidentifiers ADD 列 INT DEFAULT 7 AFTER 值",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=11 AND `e\u{0301}`=21 AND 值=31 AND 列=7"
                ),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_unicodeidentifiers CHANGE `É` 改名 BIGINT DEFAULT 15; ALTER TABLE poc.matrix_unicodeidentifiers RENAME INDEX `É` TO 键; UPDATE poc.matrix_unicodeidentifiers SET 改名=DEFAULT,`a``b`=41 WHERE id=2",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=2 AND 改名=15 AND `e\u{0301}`=20 AND `a``b`=41"
                ),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_unicodeidentifiers DROP INDEX 键, DROP COLUMN 列; DELETE FROM poc.matrix_unicodeidentifiers WHERE id=1",
                    check: "SELECT COUNT(*)=1 AND SUM(改名)=15 FROM poc.matrix_unicodeidentifiers"),
            ],
            workflow: .init(
                title: "Schema object names: Unicode columns, indexes and quoted identifiers",
                histories: [
                    .init(table: "ui_after_insert", throughPhase: 1),
                    .init(table: "ui_after_add", throughPhase: 2),
                    .init(table: "ui_after_rename", throughPhase: 3),
                ], phaseTransactions: [1, 2, 3, 2],
                predicateIDs: [
                    "inserted-defaults", "added-column-and-updated-row", "renamed-column-and-row", "deleted-final-row",
                ],
                additionalChecks: [
                    .init(
                        id: "initial-rows",
                        check: .init(
                            "SELECT id,`é`,`e\u{0301}`,值,`a``b`,`\(long)` FROM poc.ui_after_insert ORDER BY id",
                            "1\t10\t20\t30\t40\t50\n2\t10\t20\tNULL\tNULL\tNULL")),
                    .init(
                        id: "added-column-rows",
                        check: .init(
                            "SELECT id,`é`,`e\u{0301}`,值,列,`a``b`,`\(long)` FROM poc.ui_after_add ORDER BY id",
                            "1\t11\t21\t31\t7\t40\t50\n2\t10\t20\tNULL\t7\tNULL\tNULL")),
                    .init(
                        id: "renamed-rows",
                        check: .init(
                            "SELECT id,改名,`e\u{0301}`,值,列,`a``b`,`\(long)` FROM poc.ui_after_rename ORDER BY id",
                            "1\t11\t21\t31\t7\t40\t50\n2\t15\t20\tNULL\t7\t41\tNULL")),
                    .init(
                        id: "surviving-row",
                        check: .init(
                            "SELECT id,改名,`e\u{0301}`,值,`a``b`,`\(long)` FROM poc.matrix_unicodeidentifiers ORDER BY id",
                            "2\t15\t20\tNULL\t41\tNULL")),
                    .init(
                        id: "initial-column-name-bytes",
                        check: .init(
                            "SELECT HEX(COLUMN_NAME),CHAR_LENGTH(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ui_after_insert' ORDER BY ORDINAL_POSITION",
                            "6964\t2\nC3A9\t1\n65CC81\t2\nE580BC\t1\n616062\t3\n"
                                + String(repeating: "E4B8AD", count: 64) + "\t64")),
                    .init(
                        id: "renamed-column-name-bytes",
                        check: .init(
                            "SELECT HEX(COLUMN_NAME),CHAR_LENGTH(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ui_after_rename' ORDER BY ORDINAL_POSITION",
                            "6964\t2\nE694B9E5908D\t2\n65CC81\t2\nE580BC\t1\nE58897\t1\n616062\t3\n"
                                + String(repeating: "E4B8AD", count: 64) + "\t64")),
                    .init(
                        id: "final-column-name-bytes",
                        check: .init(
                            "SELECT HEX(COLUMN_NAME),CHAR_LENGTH(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_unicodeidentifiers' ORDER BY ORDINAL_POSITION",
                            "6964\t2\nE694B9E5908D\t2\n65CC81\t2\nE580BC\t1\n616062\t3\n"
                                + String(repeating: "E4B8AD", count: 64) + "\t64")),
                    .init(
                        id: "initial-index-key-parts",
                        check: .init(
                            "SELECT HEX(INDEX_NAME),SEQ_IN_INDEX,HEX(COLUMN_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ui_after_insert' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                            "65CC81\t1\t65CC81\n65CC81\t2\t6964\nC3A9\t1\tC3A9\nC3A9\t2\t6964")),
                    .init(
                        id: "renamed-index-key-parts",
                        check: .init(
                            "SELECT HEX(INDEX_NAME),SEQ_IN_INDEX,HEX(COLUMN_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ui_after_rename' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                            "65CC81\t1\t65CC81\n65CC81\t2\t6964\nE994AE\t1\tE694B9E5908D\nE994AE\t2\t6964")),
                    .init(
                        id: "surviving-index-key-parts",
                        check: .init(
                            "SELECT HEX(INDEX_NAME),SEQ_IN_INDEX,HEX(COLUMN_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_unicodeidentifiers' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                            "65CC81\t1\t65CC81\n65CC81\t2\t6964")),
                ], expectedDDL: 12, expectedRows: 14))
    }()
}

extension DDLCompatibilityCases {
    static let unicodeNames = Case(
        "unicode-names", "Schema object names: Unicode table identity, RENAME and CREATE TABLE LIKE",
        [
            .init("CREATE TABLE ddlcompat.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE ddlcompat.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO ddlcompat.`é` VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.`e\u{0301}` VALUES(1,20)"),
            .init("UPDATE ddlcompat.`é` SET 值=11 WHERE id=1"),
            .init("RENAME TABLE ddlcompat.`é` TO ddlcompat.中"),
            .init("INSERT INTO ddlcompat.中 VALUES(2,12)"),
            .init("DROP TABLE ddlcompat.`e\u{0301}`"),
            .init("CREATE TABLE ddlcompat.`select` LIKE ddlcompat.中"),
            .init("INSERT INTO ddlcompat.`select` VALUES(1,30)"),
            .init("DROP TABLE ddlcompat.中"),
            .init("DROP TABLE ddlcompat.`select`"),
            .init("CREATE TABLE ddlcompat.`😀`(id INT PRIMARY KEY,`😀` INT)"),
            .init("INSERT INTO ddlcompat.`😀` VALUES(1,40)"),
            .init("DROP TABLE ddlcompat.😀"),
            // Retain original names in un_after_insert.
            .init("CREATE DATABASE un_after_insert CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE un_after_insert.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE un_after_insert.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO un_after_insert.`é` VALUES(1,10)"),
            .init("INSERT INTO un_after_insert.`e\u{0301}` VALUES(1,20)"),
            // Retain original names in un_after_update.
            .init("CREATE DATABASE un_after_update CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE un_after_update.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE un_after_update.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO un_after_update.`é` VALUES(1,10)"),
            .init("INSERT INTO un_after_update.`e\u{0301}` VALUES(1,20)"),
            .init("UPDATE un_after_update.`é` SET 值=11 WHERE id=1"),
            // Retain original names in un_after_rename.
            .init("CREATE DATABASE un_after_rename CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE un_after_rename.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE un_after_rename.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO un_after_rename.`é` VALUES(1,10)"),
            .init("INSERT INTO un_after_rename.`e\u{0301}` VALUES(1,20)"),
            .init("UPDATE un_after_rename.`é` SET 值=11 WHERE id=1"),
            .init("RENAME TABLE un_after_rename.`é` TO un_after_rename.中"),
            .init("INSERT INTO un_after_rename.中 VALUES(2,12)"),
            // Retain original names in un_after_like.
            .init("CREATE DATABASE un_after_like CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE un_after_like.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE un_after_like.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO un_after_like.`é` VALUES(1,10)"),
            .init("INSERT INTO un_after_like.`e\u{0301}` VALUES(1,20)"),
            .init("UPDATE un_after_like.`é` SET 值=11 WHERE id=1"),
            .init("RENAME TABLE un_after_like.`é` TO un_after_like.中"),
            .init("INSERT INTO un_after_like.中 VALUES(2,12)"),
            .init("DROP TABLE un_after_like.`e\u{0301}`"),
            .init("CREATE TABLE un_after_like.`select` LIKE un_after_like.中"),
            .init("INSERT INTO un_after_like.`select` VALUES(1,30)"),
            // Retain original names in un_supplementary.
            .init("CREATE DATABASE un_supplementary CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE un_supplementary.`😀`(id INT PRIMARY KEY,`😀` INT)"),
            .init(
                "INSERT INTO un_supplementary.`😀` VALUES(1,40)", phaseEnd: "unicode-table-names-and-retained-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(id: "updated-precomposed-row", check: .init("SELECT 值 FROM un_after_update.`é`", "11")),
                .init(id: "untouched-decomposed-row", check: .init("SELECT 值 FROM un_after_update.`e\u{0301}`", "20")),
                .init(id: "renamed-table-rows", check: .init("SELECT 值 FROM un_after_rename.中 ORDER BY id", "11\n12")),
                .init(id: "native-supplementary-name-row", check: .init("SELECT `?` FROM un_supplementary.`?`", "40")),
                .init(
                    id: "inserted-precomposed-row",
                    check: .init("SELECT id,值 FROM un_after_insert.`é` ORDER BY id", "1\t10")),
                .init(
                    id: "inserted-decomposed-row",
                    check: .init("SELECT id,值 FROM un_after_insert.`e\u{0301}` ORDER BY id", "1\t20")),
                .init(
                    id: "separate-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_update' ORDER BY BINARY TABLE_NAME",
                        "65CC81\nC3A9")),
                .init(
                    id: "renamed-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_rename' ORDER BY BINARY TABLE_NAME",
                        "65CC81\nE4B8AD")),
                .init(
                    id: "quoted-like-table-row",
                    check: .init("SELECT id,值 FROM un_after_like.`select` ORDER BY id", "1\t30")),
                .init(
                    id: "like-and-drop-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_like' ORDER BY BINARY TABLE_NAME",
                        "73656C656374\nE4B8AD")),
                .init(
                    id: "native-stored-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME),HEX(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='un_supplementary' AND COLUMN_NAME<>'id' ORDER BY BINARY TABLE_NAME,ORDINAL_POSITION",
                        "3F\t3F")),
                .init(
                    id: "original-tables-dropped",
                    check: .init("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat'", "0")),
            ],
            databases: [
                "ddlcompat", "un_after_insert", "un_after_update", "un_after_rename", "un_after_like",
                "un_supplementary",
            ],
            cleanup: [
                "DROP DATABASE un_after_insert", "DROP DATABASE un_after_update", "DROP DATABASE un_after_rename",
                "DROP DATABASE un_after_like", "DROP DATABASE un_supplementary",
            ]
        ))
}
