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
        "query-encodings", "Original latin1 and Shift-JIS SQL bytes, identifiers, defaults and restart",
        [
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`{e}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{e}',b VARBINARY(10) DEFAULT '{e}',c ENUM('{e}','x') DEFAULT '{e}',eb ENUM('{e}','x') CHARACTER SET binary DEFAULT '{e}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "latin1", replacements: ["{e}": [0xe9]])),
            .init(
                "INSERT INTO ddlcompat.`é`(id) VALUES(1)",
                [.init("SELECT HEX(v),HEX(b),HEX(c),HEX(eb) FROM ddlcompat.`é`", "C3A9\tE9\tC3A9\tE9")]),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`{e}` ALTER COLUMN b SET DEFAULT '{u}'", charset: "latin1",
                    replacements: ["{e}": [0xe9], "{u}": [0xfc]]), restartBefore: true),
            .init(
                "INSERT INTO ddlcompat.`é`(id) VALUES(2)", [.init("SELECT HEX(b) FROM ddlcompat.`é` WHERE id=2", "FC")]),
            .init(
                encodedSQL(
                    "CREATE TABLE ddlcompat.`{name}`(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT '{name}',b VARBINARY(10) DEFAULT '{name}') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                    charset: "sjis", replacements: ["{name}": [0x95, 0x5c]])),
            .init(
                "INSERT INTO ddlcompat.`表`(id) VALUES(1)",
                [.init("SELECT HEX(v),HEX(b) FROM ddlcompat.`表`", "E8A1A8\t955C")]),
            .init(
                encodedSQL(
                    "ALTER TABLE ddlcompat.`{name}` ADD `{name}` INT DEFAULT 7", charset: "sjis",
                    replacements: ["{name}": [0x95, 0x5c]]), restartBefore: true),
            .init("UPDATE ddlcompat.`表` SET `表`=8 WHERE id=1", [.init("SELECT `表` FROM ddlcompat.`表`", "8")]),
            .init("DROP TABLE ddlcompat.`é`"),
            .init("DROP TABLE ddlcompat.`表`"),
        ])
}
