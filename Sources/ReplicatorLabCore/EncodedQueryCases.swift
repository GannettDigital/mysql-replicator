import Foundation

extension DDLCompatibilityCases {
    // The SQL client sends only ASCII for this step. PREPARE receives the exact
    // source bytes under SET NAMES, so neither argv nor UTF-8 can alter the test.
    static func encodedSQL(_ sql: String, charset: String, replacements: [String: [UInt8]]) -> String {
        var bytes = Data(sql.utf8)
        for (marker, value) in replacements {
            let needle = Data(marker.utf8)
            while let range = bytes.range(of: needle) { bytes.replaceSubrange(range, with: value) }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "SET NAMES " + charset + "; SET @encoded_sql=CONVERT(0x" + hex + " USING " + charset
            + "); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement"
    }
    static let encodedQueryText = Case(
        "query-encodings", "Connection character sets: latin1 and Shift-JIS Query events",
        [
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`{e}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{e}',b VARBINARY(10) DEFAULT '{e}',c ENUM('{e}','x') DEFAULT '{e}',eb ENUM('{e}','x') CHARACTER SET binary DEFAULT '{e}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "latin1", replacements: ["{e}": [0xe9]])),
            .init("INSERT INTO ddlcompat.`é`(id) VALUES(1)", phaseEnd: "create-latin1-defaults"),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`{e}` ALTER COLUMN b SET DEFAULT '{u}'", charset: "latin1",
                    replacements: ["{e}": [0xe9], "{u}": [0xfc]]), restartBefore: true),
            .init("INSERT INTO ddlcompat.`é`(id) VALUES(2)"),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`{name}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{name}',b VARBINARY(10) DEFAULT '{name}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "sjis", replacements: ["{name}": [0x95, 0x5c]])),
            .init("INSERT INTO ddlcompat.`表`(id) VALUES(1)", phaseEnd: "alter-latin1-default-and-create-sjis"),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`{name}` ADD `{name}` INT DEFAULT 7", charset: "sjis",
                    replacements: ["{name}": [0x95, 0x5c]]), restartBefore: true),
            .init("UPDATE ddlcompat.`表` SET `表`=8 WHERE id=1"),
            .init("DROP TABLE ddlcompat.`é`"),
            .init("DROP TABLE ddlcompat.`表`"),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`qe_latin1_created_{e}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{e}',b VARBINARY(10) DEFAULT '{e}',c ENUM('{e}','x') DEFAULT '{e}',eb ENUM('{e}','x') CHARACTER SET binary DEFAULT '{e}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "latin1", replacements: ["{e}": [0xe9]])),
            .init("INSERT INTO ddlcompat.`qe_latin1_created_é`(id) VALUES(1)"),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`qe_latin1_altered_{e}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{e}',b VARBINARY(10) DEFAULT '{e}',c ENUM('{e}','x') DEFAULT '{e}',eb ENUM('{e}','x') CHARACTER SET binary DEFAULT '{e}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "latin1", replacements: ["{e}": [0xe9]])),
            .init("INSERT INTO ddlcompat.`qe_latin1_altered_é`(id) VALUES(1)"),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`qe_latin1_altered_{e}` ALTER COLUMN b SET DEFAULT '{u}'", charset: "latin1",
                    replacements: ["{e}": [0xe9], "{u}": [0xfc]])),
            .init("INSERT INTO ddlcompat.`qe_latin1_altered_é`(id) VALUES(2)"),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`qe_sjis_created_{name}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{name}',b VARBINARY(10) DEFAULT '{name}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "sjis", replacements: ["{name}": [0x95, 0x5c]])),
            .init("INSERT INTO ddlcompat.`qe_sjis_created_表`(id) VALUES(1)"),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`qe_sjis_added_{name}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{name}',b VARBINARY(10) DEFAULT '{name}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "sjis", replacements: ["{name}": [0x95, 0x5c]])),
            .init("INSERT INTO ddlcompat.`qe_sjis_added_表`(id) VALUES(1)"),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`qe_sjis_added_{name}` ADD `{name}` INT DEFAULT 7", charset: "sjis",
                    replacements: ["{name}": [0x95, 0x5c]])),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`qe_sjis_updated_{name}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{name}',b VARBINARY(10) DEFAULT '{name}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "sjis", replacements: ["{name}": [0x95, 0x5c]])),
            .init("INSERT INTO ddlcompat.`qe_sjis_updated_表`(id) VALUES(1)"),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`qe_sjis_updated_{name}` ADD `{name}` INT DEFAULT 7", charset: "sjis",
                    replacements: ["{name}": [0x95, 0x5c]])),
            .init(
                "UPDATE ddlcompat.`qe_sjis_updated_表` SET `表`=8 WHERE id=1",
                phaseEnd: "alter-sjis-drop-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "latin1-created-default-bytes",
                    check: .init(
                        "SELECT HEX(v),HEX(b),HEX(c),HEX(eb) FROM ddlcompat.`qe_latin1_created_é`", "C3A9\tE9\tC3A9\tE9"
                    )),
                .init(
                    id: "latin1-altered-default-byte",
                    check: .init("SELECT HEX(b) FROM ddlcompat.`qe_latin1_altered_é` WHERE id=2", "FC")),
                .init(
                    id: "sjis-created-default-bytes",
                    check: .init("SELECT HEX(v),HEX(b) FROM ddlcompat.`qe_sjis_created_表`", "E8A1A8\t955C")),
                .init(id: "sjis-updated-column", check: .init("SELECT `表` FROM ddlcompat.`qe_sjis_updated_表`", "8")),
                .init(
                    id: "latin1-existing-and-new-defaults",
                    check: .init(
                        "SELECT id,HEX(v),HEX(b),HEX(c),HEX(eb) FROM ddlcompat.`qe_latin1_altered_é` ORDER BY id",
                        "1\tC3A9\tE9\tC3A9\tE9\n2\tC3A9\tFC\tC3A9\tE9")),
                .init(
                    id: "sjis-materialized-column-default",
                    check: .init(
                        "SELECT id,HEX(v),HEX(b),`表` FROM ddlcompat.`qe_sjis_added_表` ORDER BY id", "1\tE8A1A8\t955C\t7"
                    )),
                .init(
                    id: "sjis-updated-row-bytes",
                    check: .init(
                        "SELECT id,HEX(v),HEX(b),`表` FROM ddlcompat.`qe_sjis_updated_表` ORDER BY id",
                        "1\tE8A1A8\t955C\t8")),
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND BINARY TABLE_NAME IN ('é','表')",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.`qe_latin1_created_é`,ddlcompat.`qe_latin1_altered_é`,ddlcompat.`qe_sjis_created_表`,ddlcompat.`qe_sjis_added_表`,ddlcompat.`qe_sjis_updated_表`"
            ]
        ))
}
