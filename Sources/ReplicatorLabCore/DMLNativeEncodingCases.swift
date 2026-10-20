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
            ])
    }()
}
