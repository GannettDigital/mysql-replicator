import Foundation

extension DDLCompatibilityCases {
    static let tableNameCase = Case(
        "table-name-case", "Identifier case sensitivity: lower_case_table_names=1, LIKE and RENAME",
        [
            .init("CREATE TABLE ddlcompat.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO DDLCOMPAT.`mixé`(id) VALUES(1)", phaseEnd: "insert-through-mixed-case-names"),
            .init("ALTER TABLE DDLCOMPAT.`MIXÉ` ADD extra INT DEFAULT 3", restartBefore: true),
            .init("UPDATE ddlcompat.`mixé` SET extra=9 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.`CoPy` LIKE DDLCOMPAT.`MIXÉ`"),
            .init("INSERT INTO ddlcompat.`COPY` SELECT * FROM ddlcompat.`mixé`"),
            .init(
                "RENAME TABLE DDLCOMPAT.`COPY` TO ddlcompat.`Final`,ddlcompat.`MiXÉ` TO ddlcompat.`Old`",
                phaseEnd: "alter-copy-and-rename-tables"),
            .init("UPDATE ddlcompat.`FINAL` SET n=8 WHERE id=1", restartBefore: true),
            .init("DROP TABLE ddlcompat.`OLD`"),
            .init("DROP TABLE ddlcompat.`FINAL`"),
            // Retain original table spellings in lc_after_insert.
            .init("CREATE DATABASE lc_after_insert CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE lc_after_insert.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO LC_AFTER_INSERT.`mixé`(id) VALUES(1)"),
            // Retain original table spellings in lc_after_add.
            .init("CREATE DATABASE lc_after_add CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE lc_after_add.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO LC_AFTER_ADD.`mixé`(id) VALUES(1)"),
            .init("ALTER TABLE LC_AFTER_ADD.`MIXÉ` ADD extra INT DEFAULT 3"),
            // Retain original table spellings in lc_after_copy.
            .init("CREATE DATABASE lc_after_copy CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE lc_after_copy.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO LC_AFTER_COPY.`mixé`(id) VALUES(1)"),
            .init("ALTER TABLE LC_AFTER_COPY.`MIXÉ` ADD extra INT DEFAULT 3"),
            .init("UPDATE lc_after_copy.`mixé` SET extra=9 WHERE id=1"),
            .init("CREATE TABLE lc_after_copy.`CoPy` LIKE LC_AFTER_COPY.`MIXÉ`"),
            .init("INSERT INTO lc_after_copy.`COPY` SELECT * FROM lc_after_copy.`mixé`"),
            // Retain original table spellings in lc_after_rename.
            .init("CREATE DATABASE lc_after_rename CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE lc_after_rename.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)"),
            .init("INSERT INTO LC_AFTER_RENAME.`mixé`(id) VALUES(1)"),
            .init("ALTER TABLE LC_AFTER_RENAME.`MIXÉ` ADD extra INT DEFAULT 3"),
            .init("UPDATE lc_after_rename.`mixé` SET extra=9 WHERE id=1"),
            .init("CREATE TABLE lc_after_rename.`CoPy` LIKE LC_AFTER_RENAME.`MIXÉ`"),
            .init("INSERT INTO lc_after_rename.`COPY` SELECT * FROM lc_after_rename.`mixé`"),
            .init(
                "RENAME TABLE LC_AFTER_RENAME.`COPY` TO lc_after_rename.`Final`,lc_after_rename.`MiXÉ` TO lc_after_rename.`Old`"
            ),
            .init("UPDATE lc_after_rename.`FINAL` SET n=8 WHERE id=1", phaseEnd: "update-drop-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "inserted-default-through-uppercase-name",
                    check: .init("SELECT ID,n FROM lc_after_insert.`MIXÉ`", "1\t7")),
                .init(
                    id: "updated-renamed-copy",
                    check: .init("SELECT ID,n,extra FROM lc_after_rename.`final`", "1\t8\t9")),
                .init(
                    id: "materialized-added-default",
                    check: .init("SELECT ID,n,extra FROM lc_after_add.`mixé` ORDER BY ID", "1\t7\t3")),
                .init(
                    id: "updated-copy-source",
                    check: .init("SELECT ID,n,extra FROM lc_after_copy.`MIXÉ` ORDER BY ID", "1\t7\t9")),
                .init(
                    id: "copied-row", check: .init("SELECT ID,n,extra FROM lc_after_copy.`COPY` ORDER BY ID", "1\t7\t9")
                ),
                .init(
                    id: "unchanged-renamed-original",
                    check: .init("SELECT ID,n,extra FROM lc_after_rename.`OLD` ORDER BY ID", "1\t7\t9")),
                .init(
                    id: "lowercase-copy-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='lc_after_copy' ORDER BY BINARY TABLE_NAME",
                        "636F7079\n6D6978C3A9")),
                .init(
                    id: "lowercase-rename-name-bytes",
                    check: .init(
                        "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='lc_after_rename' ORDER BY BINARY TABLE_NAME",
                        "66696E616C\n6F6C64")),
                .init(
                    id: "stored-column-name-bytes",
                    check: .init(
                        "SELECT HEX(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='lc_after_add' ORDER BY ORDINAL_POSITION",
                        "4944\n6E\n6578747261")),
                .init(
                    id: "original-tables-dropped",
                    check: .init("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat'", "0")),
            ], databases: ["ddlcompat", "lc_after_insert", "lc_after_add", "lc_after_copy", "lc_after_rename"],
            cleanup: [
                "DROP DATABASE lc_after_insert", "DROP DATABASE lc_after_add", "DROP DATABASE lc_after_copy",
                "DROP DATABASE lc_after_rename",
            ]
        ))
}
