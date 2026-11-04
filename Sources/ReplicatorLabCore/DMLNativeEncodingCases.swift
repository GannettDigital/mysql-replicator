import Foundation

extension DMLCompatibilityCases {
    static let nativeEncodings: Case = {
        // Native byte vectors. Do not build expectations by converting the
        // source text through the implementation under test.
        let encodings: [(String, String, String, String)] = [
            ("armscii8", "armscii8_bin", "B20020", "B200"),
            ("big5", "big5_bin", "A4A40020", "A4A400"),
            ("cp1250", "cp1250_polish_ci", "C00020", "C000"),
            ("cp1251", "cp1251_general_cs", "C00020", "C000"),
            ("cp1256", "cp1256_bin", "C10020", "C100"),
            ("cp1257", "cp1257_general_ci", "C00020", "C000"),
            ("cp850", "cp850_bin", "820020", "8200"),
            ("cp852", "cp852_bin", "800020", "8000"),
            ("cp866", "cp866_bin", "800020", "8000"),
            ("cp932", "cp932_bin", "82A00020", "82A000"),
            ("dec8", "dec8_bin", "C40020", "C400"),
            ("eucjpms", "eucjpms_bin", "A4A20020", "A4A200"),
            ("euckr", "euckr_bin", "B0A10020", "B0A100"),
            ("gb18030", "gb18030_unicode_520_ci", "D6D00020", "D6D000"),
            ("gb2312", "gb2312_bin", "D6D00020", "D6D000"),
            ("gbk", "gbk_bin", "D6D00020", "D6D000"),
            ("geostd8", "geostd8_bin", "C00020", "C000"),
            ("greek", "greek_bin", "C10020", "C100"),
            ("hebrew", "hebrew_bin", "E00020", "E000"),
            ("hp8", "hp8_bin", "C40020", "C400"),
            ("keybcs2", "keybcs2_bin", "800020", "8000"),
            ("koi8r", "koi8r_bin", "C10020", "C100"),
            ("koi8u", "koi8u_bin", "C10020", "C100"),
            ("latin2", "latin2_bin", "A10020", "A100"),
            ("latin5", "latin5_bin", "D00020", "D000"),
            ("latin7", "latin7_bin", "C00020", "C000"),
            ("macce", "macce_bin", "800020", "8000"),
            ("macroman", "macroman_bin", "800020", "8000"),
            ("sjis", "sjis_bin", "82A00020", "82A000"),
            ("swe7", "swe7_bin", "5B0020", "5B00"),
            ("tis620", "tis620_bin", "A10020", "A100"),
            ("ucs2", "ucs2_general_mysql500_ci", "202000000020", "20200000"),
            ("ujis", "ujis_bin", "A4A20020", "A4A200"),
            ("utf16", "utf16_vietnamese_ci", "D83DDE00202000000020", "D83DDE0020200000"),
            ("utf16le", "utf16le_bin", "0020202000002000", "002020200000"),
            ("utf32", "utf32_vietnamese_ci", "000020200000000000000020", "0000202000000000"),
        ]
        let definitions = encodings.flatMap { cs, collation, _, _ in
            [
                "c_\(cs) CHAR(4) CHARACTER SET \(cs) COLLATE \(collation) DEFAULT 'A'",
                "v_\(cs) VARCHAR(12) CHARACTER SET \(cs) COLLATE \(collation)",
                "t_\(cs) TEXT CHARACTER SET \(cs) COLLATE \(collation)",
            ]
        }
        let names = encodings.flatMap { cs, _, _, _ in ["c_\(cs)", "v_\(cs)", "t_\(cs)"] }
        let values = encodings.flatMap { cs, _, hex, _ in Array(repeating: "CONVERT(0x\(hex) USING \(cs))", count: 3) }
        let checks = encodings.flatMap { cs, _, hex, trimmed in
            ["HEX(c_\(cs))='\(trimmed)'", "HEX(v_\(cs))='\(hex)'", "HEX(t_\(cs))='\(hex)'"]
        }.joined(separator: " AND ")
        let empty = names.map { "\($0)=NULL" }.joined(separator: ",")
        // Fixed native IDs; keep expectations independent of the apply registry.
        let collationIDs: [String: Int] = [
            "armscii8": 64,
            "big5": 84,
            "cp1250": 99,
            "cp1251": 52,
            "cp1256": 67,
            "cp1257": 59,
            "cp850": 80,
            "cp852": 81,
            "cp866": 68,
            "cp932": 96,
            "dec8": 69,
            "eucjpms": 98,
            "euckr": 85,
            "gb18030": 250,
            "gb2312": 86,
            "gbk": 87,
            "geostd8": 93,
            "greek": 70,
            "hebrew": 71,
            "hp8": 72,
            "keybcs2": 73,
            "koi8r": 74,
            "koi8u": 75,
            "latin2": 77,
            "latin5": 78,
            "latin7": 79,
            "macce": 43,
            "macroman": 53,
            "sjis": 88,
            "swe7": 82,
            "tis620": 89,
            "ucs2": 159,
            "ujis": 91,
            "utf16": 124,
            "utf16le": 62,
            "utf32": 183,
        ]
        func row(_ key: String, updated: Bool = false, cleared: Bool = false, extra: String? = nil) -> String {
            var fields = encodings.flatMap { charset, _, full, trimmed -> [String] in
                if cleared { return ["NULL", "NULL", "NULL"] }
                if updated { return [trimmed, full, full] }
                let initial =
                    charset == "ucs2" || charset == "utf16"
                    ? "0041"
                    : charset == "utf16le" ? "4100" : charset == "utf32" ? "00000041" : "41"
                return [initial, "NULL", "NULL"]
            }
            if let extra { fields.append(extra) }
            return ([key] + fields).joined(separator: "\t")
        }
        func rows(_ table: String, added: Bool = false, expected: String, id: String)
            -> DDLFinalObservations.Observation
        {
            let fields = ["HEX(id)"] + (names + (added ? ["extra"] : [])).map { "IFNULL(HEX(\($0)),'NULL')" }
            return .init(
                id: id,
                check: .init(
                    "SELECT " + fields.joined(separator: ",") + " FROM poc." + table + " ORDER BY BINARY id", expected))
        }
        func metadata(_ table: String, added: Bool, id: String) -> DDLFinalObservations.Observation {
            var fields =
                ["id\t55\tutf16\tutf16_bin"]
                + encodings.flatMap { charset, collation, _, _ in
                    ["c_", "v_", "t_"].map { "\($0)\(charset)\t\(collationIDs[charset]!)\t\(charset)\t\(collation)" }
                }
            if added { fields.append("extra\t249\tgb18030\tgb18030_bin") }
            return .init(
                id: id,
                check: .init(
                    "SELECT c.COLUMN_NAME,k.ID,c.CHARACTER_SET_NAME,c.COLLATION_NAME FROM information_schema.COLUMNS c JOIN information_schema.COLLATIONS k ON k.COLLATION_NAME=c.COLLATION_NAME WHERE c.TABLE_SCHEMA='poc' AND c.TABLE_NAME='\(table)' ORDER BY c.ORDINAL_POSITION",
                    fields.joined(separator: "\n")))
        }
        return Case(
            id: "nativeencodings",
            definition: "id VARCHAR(12) CHARACTER SET utf16 COLLATE utf16_bin PRIMARY KEY,"
                + definitions.joined(separator: ","),
            phases: [
                .init(
                    sql: "INSERT INTO poc.matrix_nativeencodings(id) VALUES('first'),('second')",
                    check:
                        "SELECT COUNT(*)=2 AND SUM(HEX(c_ucs2)='0041')=2 AND SUM(HEX(c_utf32)='00000041')=2 FROM poc.matrix_nativeencodings"
                ),
                .init(
                    sql: "UPDATE poc.matrix_nativeencodings SET id='changed',"
                        + zip(names, values).map { "\($0)=\($1)" }.joined(separator: ",") + " WHERE id='first'",
                    check: "SELECT COUNT(*)=1 FROM poc.matrix_nativeencodings WHERE id='changed' AND " + checks),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_nativeencodings ADD extra VARCHAR(4) CHARACTER SET gb18030 COLLATE gb18030_bin; UPDATE poc.matrix_nativeencodings SET "
                        + empty + ",extra=CONVERT(0x9439FC36 USING gb18030) WHERE id='second'",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_nativeencodings WHERE id='second' AND c_ucs2 IS NULL AND t_big5 IS NULL AND HEX(extra)='9439FC36'"
                ),
                .init(
                    sql: "DELETE FROM poc.matrix_nativeencodings WHERE id='changed'",
                    check: "SELECT COUNT(*)=1 AND MIN(id)='second' FROM poc.matrix_nativeencodings"),
            ],
            workflow: .init(
                title: "Character sets: CHAR, VARCHAR and TEXT byte values and multibyte keys",
                histories: [
                    .init(table: "ne_after_insert", throughPhase: 1),
                    .init(table: "ne_after_update", throughPhase: 2),
                    .init(table: "ne_after_add", throughPhase: 3),
                ], phaseTransactions: [1, 1, 2, 1],
                predicateIDs: [
                    "inserted-defaults", "updated-bytes-and-key", "added-column-and-null-fields", "deleted-changed-key",
                ],
                additionalChecks: [
                    rows(
                        "ne_after_insert",
                        expected: row("00660069007200730074") + "\n" + row("007300650063006F006E0064"),
                        id: "initial-rows"),
                    rows(
                        "ne_after_update",
                        expected: row("006300680061006E006700650064", updated: true) + "\n"
                            + row("007300650063006F006E0064"),
                        id: "updated-rows"),
                    rows(
                        "ne_after_add", added: true,
                        expected: row("006300680061006E006700650064", updated: true, extra: "NULL") + "\n"
                            + row("007300650063006F006E0064", cleared: true, extra: "9439FC36"),
                        id: "added-column-rows"),
                    rows(
                        "matrix_nativeencodings", added: true,
                        expected: row("007300650063006F006E0064", cleared: true, extra: "9439FC36"),
                        id: "surviving-row"),
                    metadata("ne_after_update", added: false, id: "original-character-set-ids"),
                    metadata("ne_after_add", added: true, id: "added-character-set-ids"),
                ], expectedDDL: 6, expectedRows: 14))
    }()
}
