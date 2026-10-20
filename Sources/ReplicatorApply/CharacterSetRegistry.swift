/// Registry for the encodings used by the applier. Native
/// identity does not imply that column transport supports the encoding.
/// IDs and names follow the pinned MySQL strings/ctype-utf8, ctype-uca and
/// ctype-latin1 definitions. Extend this list with codec and native tests.
enum CharacterSetRegistry {
    enum Server { case mysql57, mysql84 }
    struct Collation {
        let id: UInt32
        /// Canonical encoding identity; MySQL 5.7 calls utf8mb3 "utf8".
        let characterSet: String
        let name57: String?
        let name84: String
        let supportsColumns: Bool

        func name(on server: Server) -> String? {
            server == .mysql57 ? name57 : name84
        }
        var diagnosticName: String {
            if let name57, name57 != name84 { return name57 + " (5.7), " + name84 + " (8.4)" }
            return name84
        }
    }

    static let collations: [Collation] = [
        .init(id: 1, characterSet: "big5", name57: "big5_chinese_ci", name84: "big5_chinese_ci", supportsColumns: true),
        .init(
            id: 2, characterSet: "latin2", name57: "latin2_czech_cs", name84: "latin2_czech_cs", supportsColumns: true),
        .init(id: 3, characterSet: "dec8", name57: "dec8_swedish_ci", name84: "dec8_swedish_ci", supportsColumns: true),
        .init(
            id: 4, characterSet: "cp850", name57: "cp850_general_ci", name84: "cp850_general_ci", supportsColumns: true),
        .init(
            id: 5, characterSet: "latin1", name57: "latin1_german1_ci", name84: "latin1_german1_ci",
            supportsColumns: true),
        .init(id: 6, characterSet: "hp8", name57: "hp8_english_ci", name84: "hp8_english_ci", supportsColumns: true),
        .init(
            id: 7, characterSet: "koi8r", name57: "koi8r_general_ci", name84: "koi8r_general_ci", supportsColumns: true),
        .init(
            id: 8, characterSet: "latin1", name57: "latin1_swedish_ci", name84: "latin1_swedish_ci",
            supportsColumns: true),
        .init(
            id: 9, characterSet: "latin2", name57: "latin2_general_ci", name84: "latin2_general_ci",
            supportsColumns: true),
        .init(
            id: 10, characterSet: "swe7", name57: "swe7_swedish_ci", name84: "swe7_swedish_ci", supportsColumns: true),
        .init(
            id: 11, characterSet: "ascii", name57: "ascii_general_ci", name84: "ascii_general_ci", supportsColumns: true
        ),
        .init(
            id: 12, characterSet: "ujis", name57: "ujis_japanese_ci", name84: "ujis_japanese_ci", supportsColumns: true),
        .init(
            id: 13, characterSet: "sjis", name57: "sjis_japanese_ci", name84: "sjis_japanese_ci", supportsColumns: true),
        .init(
            id: 14, characterSet: "cp1251", name57: "cp1251_bulgarian_ci", name84: "cp1251_bulgarian_ci",
            supportsColumns: true),
        .init(
            id: 15, characterSet: "latin1", name57: "latin1_danish_ci", name84: "latin1_danish_ci",
            supportsColumns: true),
        .init(
            id: 16, characterSet: "hebrew", name57: "hebrew_general_ci", name84: "hebrew_general_ci",
            supportsColumns: true),
        .init(
            id: 18, characterSet: "tis620", name57: "tis620_thai_ci", name84: "tis620_thai_ci", supportsColumns: true),
        .init(
            id: 19, characterSet: "euckr", name57: "euckr_korean_ci", name84: "euckr_korean_ci", supportsColumns: true),
        .init(
            id: 20, characterSet: "latin7", name57: "latin7_estonian_cs", name84: "latin7_estonian_cs",
            supportsColumns: true),
        .init(
            id: 21, characterSet: "latin2", name57: "latin2_hungarian_ci", name84: "latin2_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 22, characterSet: "koi8u", name57: "koi8u_general_ci", name84: "koi8u_general_ci", supportsColumns: true
        ),
        .init(
            id: 23, characterSet: "cp1251", name57: "cp1251_ukrainian_ci", name84: "cp1251_ukrainian_ci",
            supportsColumns: true),
        .init(
            id: 24, characterSet: "gb2312", name57: "gb2312_chinese_ci", name84: "gb2312_chinese_ci",
            supportsColumns: true),
        .init(
            id: 25, characterSet: "greek", name57: "greek_general_ci", name84: "greek_general_ci", supportsColumns: true
        ),
        .init(
            id: 26, characterSet: "cp1250", name57: "cp1250_general_ci", name84: "cp1250_general_ci",
            supportsColumns: true),
        .init(
            id: 27, characterSet: "latin2", name57: "latin2_croatian_ci", name84: "latin2_croatian_ci",
            supportsColumns: true),
        .init(id: 28, characterSet: "gbk", name57: "gbk_chinese_ci", name84: "gbk_chinese_ci", supportsColumns: true),
        .init(
            id: 29, characterSet: "cp1257", name57: "cp1257_lithuanian_ci", name84: "cp1257_lithuanian_ci",
            supportsColumns: true),
        .init(
            id: 30, characterSet: "latin5", name57: "latin5_turkish_ci", name84: "latin5_turkish_ci",
            supportsColumns: true),
        .init(
            id: 31, characterSet: "latin1", name57: "latin1_german2_ci", name84: "latin1_german2_ci",
            supportsColumns: true),
        .init(
            id: 32, characterSet: "armscii8", name57: "armscii8_general_ci", name84: "armscii8_general_ci",
            supportsColumns: true),
        .init(
            id: 33, characterSet: "utf8mb3", name57: "utf8_general_ci", name84: "utf8mb3_general_ci",
            supportsColumns: true),
        .init(
            id: 34, characterSet: "cp1250", name57: "cp1250_czech_cs", name84: "cp1250_czech_cs", supportsColumns: true),
        .init(
            id: 35, characterSet: "ucs2", name57: "ucs2_general_ci", name84: "ucs2_general_ci", supportsColumns: true),
        .init(
            id: 36, characterSet: "cp866", name57: "cp866_general_ci", name84: "cp866_general_ci", supportsColumns: true
        ),
        .init(
            id: 37, characterSet: "keybcs2", name57: "keybcs2_general_ci", name84: "keybcs2_general_ci",
            supportsColumns: true),
        .init(
            id: 38, characterSet: "macce", name57: "macce_general_ci", name84: "macce_general_ci", supportsColumns: true
        ),
        .init(
            id: 39, characterSet: "macroman", name57: "macroman_general_ci", name84: "macroman_general_ci",
            supportsColumns: true),
        .init(
            id: 40, characterSet: "cp852", name57: "cp852_general_ci", name84: "cp852_general_ci", supportsColumns: true
        ),
        .init(
            id: 41, characterSet: "latin7", name57: "latin7_general_ci", name84: "latin7_general_ci",
            supportsColumns: true),
        .init(
            id: 42, characterSet: "latin7", name57: "latin7_general_cs", name84: "latin7_general_cs",
            supportsColumns: true),
        .init(id: 43, characterSet: "macce", name57: "macce_bin", name84: "macce_bin", supportsColumns: true),
        .init(
            id: 44, characterSet: "cp1250", name57: "cp1250_croatian_ci", name84: "cp1250_croatian_ci",
            supportsColumns: true),
        .init(
            id: 45, characterSet: "utf8mb4", name57: "utf8mb4_general_ci", name84: "utf8mb4_general_ci",
            supportsColumns: true),
        .init(id: 46, characterSet: "utf8mb4", name57: "utf8mb4_bin", name84: "utf8mb4_bin", supportsColumns: true),
        .init(id: 47, characterSet: "latin1", name57: "latin1_bin", name84: "latin1_bin", supportsColumns: true),
        .init(
            id: 48, characterSet: "latin1", name57: "latin1_general_ci", name84: "latin1_general_ci",
            supportsColumns: true),
        .init(
            id: 49, characterSet: "latin1", name57: "latin1_general_cs", name84: "latin1_general_cs",
            supportsColumns: true),
        .init(id: 50, characterSet: "cp1251", name57: "cp1251_bin", name84: "cp1251_bin", supportsColumns: true),
        .init(
            id: 51, characterSet: "cp1251", name57: "cp1251_general_ci", name84: "cp1251_general_ci",
            supportsColumns: true),
        .init(
            id: 52, characterSet: "cp1251", name57: "cp1251_general_cs", name84: "cp1251_general_cs",
            supportsColumns: true),
        .init(id: 53, characterSet: "macroman", name57: "macroman_bin", name84: "macroman_bin", supportsColumns: true),
        .init(
            id: 54, characterSet: "utf16", name57: "utf16_general_ci", name84: "utf16_general_ci", supportsColumns: true
        ),
        .init(id: 55, characterSet: "utf16", name57: "utf16_bin", name84: "utf16_bin", supportsColumns: true),
        .init(
            id: 56, characterSet: "utf16le", name57: "utf16le_general_ci", name84: "utf16le_general_ci",
            supportsColumns: true),
        .init(
            id: 57, characterSet: "cp1256", name57: "cp1256_general_ci", name84: "cp1256_general_ci",
            supportsColumns: true),
        .init(id: 58, characterSet: "cp1257", name57: "cp1257_bin", name84: "cp1257_bin", supportsColumns: true),
        .init(
            id: 59, characterSet: "cp1257", name57: "cp1257_general_ci", name84: "cp1257_general_ci",
            supportsColumns: true),
        .init(
            id: 60, characterSet: "utf32", name57: "utf32_general_ci", name84: "utf32_general_ci", supportsColumns: true
        ),
        .init(id: 61, characterSet: "utf32", name57: "utf32_bin", name84: "utf32_bin", supportsColumns: true),
        .init(id: 62, characterSet: "utf16le", name57: "utf16le_bin", name84: "utf16le_bin", supportsColumns: true),
        .init(id: 63, characterSet: "binary", name57: "binary", name84: "binary", supportsColumns: false),
        .init(id: 64, characterSet: "armscii8", name57: "armscii8_bin", name84: "armscii8_bin", supportsColumns: true),
        .init(id: 65, characterSet: "ascii", name57: "ascii_bin", name84: "ascii_bin", supportsColumns: true),
        .init(id: 66, characterSet: "cp1250", name57: "cp1250_bin", name84: "cp1250_bin", supportsColumns: true),
        .init(id: 67, characterSet: "cp1256", name57: "cp1256_bin", name84: "cp1256_bin", supportsColumns: true),
        .init(id: 68, characterSet: "cp866", name57: "cp866_bin", name84: "cp866_bin", supportsColumns: true),
        .init(id: 69, characterSet: "dec8", name57: "dec8_bin", name84: "dec8_bin", supportsColumns: true),
        .init(id: 70, characterSet: "greek", name57: "greek_bin", name84: "greek_bin", supportsColumns: true),
        .init(id: 71, characterSet: "hebrew", name57: "hebrew_bin", name84: "hebrew_bin", supportsColumns: true),
        .init(id: 72, characterSet: "hp8", name57: "hp8_bin", name84: "hp8_bin", supportsColumns: true),
        .init(id: 73, characterSet: "keybcs2", name57: "keybcs2_bin", name84: "keybcs2_bin", supportsColumns: true),
        .init(id: 74, characterSet: "koi8r", name57: "koi8r_bin", name84: "koi8r_bin", supportsColumns: true),
        .init(id: 75, characterSet: "koi8u", name57: "koi8u_bin", name84: "koi8u_bin", supportsColumns: true),
        .init(id: 77, characterSet: "latin2", name57: "latin2_bin", name84: "latin2_bin", supportsColumns: true),
        .init(id: 78, characterSet: "latin5", name57: "latin5_bin", name84: "latin5_bin", supportsColumns: true),
        .init(id: 79, characterSet: "latin7", name57: "latin7_bin", name84: "latin7_bin", supportsColumns: true),
        .init(id: 80, characterSet: "cp850", name57: "cp850_bin", name84: "cp850_bin", supportsColumns: true),
        .init(id: 81, characterSet: "cp852", name57: "cp852_bin", name84: "cp852_bin", supportsColumns: true),
        .init(id: 82, characterSet: "swe7", name57: "swe7_bin", name84: "swe7_bin", supportsColumns: true),
        .init(id: 83, characterSet: "utf8mb3", name57: "utf8_bin", name84: "utf8mb3_bin", supportsColumns: true),
        .init(id: 84, characterSet: "big5", name57: "big5_bin", name84: "big5_bin", supportsColumns: true),
        .init(id: 85, characterSet: "euckr", name57: "euckr_bin", name84: "euckr_bin", supportsColumns: true),
        .init(id: 86, characterSet: "gb2312", name57: "gb2312_bin", name84: "gb2312_bin", supportsColumns: true),
        .init(id: 87, characterSet: "gbk", name57: "gbk_bin", name84: "gbk_bin", supportsColumns: true),
        .init(id: 88, characterSet: "sjis", name57: "sjis_bin", name84: "sjis_bin", supportsColumns: true),
        .init(id: 89, characterSet: "tis620", name57: "tis620_bin", name84: "tis620_bin", supportsColumns: true),
        .init(id: 90, characterSet: "ucs2", name57: "ucs2_bin", name84: "ucs2_bin", supportsColumns: true),
        .init(id: 91, characterSet: "ujis", name57: "ujis_bin", name84: "ujis_bin", supportsColumns: true),
        .init(
            id: 92, characterSet: "geostd8", name57: "geostd8_general_ci", name84: "geostd8_general_ci",
            supportsColumns: true),
        .init(id: 93, characterSet: "geostd8", name57: "geostd8_bin", name84: "geostd8_bin", supportsColumns: true),
        .init(
            id: 94, characterSet: "latin1", name57: "latin1_spanish_ci", name84: "latin1_spanish_ci",
            supportsColumns: true),
        .init(
            id: 95, characterSet: "cp932", name57: "cp932_japanese_ci", name84: "cp932_japanese_ci",
            supportsColumns: true),
        .init(id: 96, characterSet: "cp932", name57: "cp932_bin", name84: "cp932_bin", supportsColumns: true),
        .init(
            id: 97, characterSet: "eucjpms", name57: "eucjpms_japanese_ci", name84: "eucjpms_japanese_ci",
            supportsColumns: true),
        .init(id: 98, characterSet: "eucjpms", name57: "eucjpms_bin", name84: "eucjpms_bin", supportsColumns: true),
        .init(
            id: 99, characterSet: "cp1250", name57: "cp1250_polish_ci", name84: "cp1250_polish_ci",
            supportsColumns: true),
        .init(
            id: 101, characterSet: "utf16", name57: "utf16_unicode_ci", name84: "utf16_unicode_ci",
            supportsColumns: true),
        .init(
            id: 102, characterSet: "utf16", name57: "utf16_icelandic_ci", name84: "utf16_icelandic_ci",
            supportsColumns: true),
        .init(
            id: 103, characterSet: "utf16", name57: "utf16_latvian_ci", name84: "utf16_latvian_ci",
            supportsColumns: true),
        .init(
            id: 104, characterSet: "utf16", name57: "utf16_romanian_ci", name84: "utf16_romanian_ci",
            supportsColumns: true),
        .init(
            id: 105, characterSet: "utf16", name57: "utf16_slovenian_ci", name84: "utf16_slovenian_ci",
            supportsColumns: true),
        .init(
            id: 106, characterSet: "utf16", name57: "utf16_polish_ci", name84: "utf16_polish_ci", supportsColumns: true),
        .init(
            id: 107, characterSet: "utf16", name57: "utf16_estonian_ci", name84: "utf16_estonian_ci",
            supportsColumns: true),
        .init(
            id: 108, characterSet: "utf16", name57: "utf16_spanish_ci", name84: "utf16_spanish_ci",
            supportsColumns: true),
        .init(
            id: 109, characterSet: "utf16", name57: "utf16_swedish_ci", name84: "utf16_swedish_ci",
            supportsColumns: true),
        .init(
            id: 110, characterSet: "utf16", name57: "utf16_turkish_ci", name84: "utf16_turkish_ci",
            supportsColumns: true),
        .init(
            id: 111, characterSet: "utf16", name57: "utf16_czech_ci", name84: "utf16_czech_ci", supportsColumns: true),
        .init(
            id: 112, characterSet: "utf16", name57: "utf16_danish_ci", name84: "utf16_danish_ci", supportsColumns: true),
        .init(
            id: 113, characterSet: "utf16", name57: "utf16_lithuanian_ci", name84: "utf16_lithuanian_ci",
            supportsColumns: true),
        .init(
            id: 114, characterSet: "utf16", name57: "utf16_slovak_ci", name84: "utf16_slovak_ci", supportsColumns: true),
        .init(
            id: 115, characterSet: "utf16", name57: "utf16_spanish2_ci", name84: "utf16_spanish2_ci",
            supportsColumns: true),
        .init(
            id: 116, characterSet: "utf16", name57: "utf16_roman_ci", name84: "utf16_roman_ci", supportsColumns: true),
        .init(
            id: 117, characterSet: "utf16", name57: "utf16_persian_ci", name84: "utf16_persian_ci",
            supportsColumns: true),
        .init(
            id: 118, characterSet: "utf16", name57: "utf16_esperanto_ci", name84: "utf16_esperanto_ci",
            supportsColumns: true),
        .init(
            id: 119, characterSet: "utf16", name57: "utf16_hungarian_ci", name84: "utf16_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 120, characterSet: "utf16", name57: "utf16_sinhala_ci", name84: "utf16_sinhala_ci",
            supportsColumns: true),
        .init(
            id: 121, characterSet: "utf16", name57: "utf16_german2_ci", name84: "utf16_german2_ci",
            supportsColumns: true),
        .init(
            id: 122, characterSet: "utf16", name57: "utf16_croatian_ci", name84: "utf16_croatian_ci",
            supportsColumns: true),
        .init(
            id: 123, characterSet: "utf16", name57: "utf16_unicode_520_ci", name84: "utf16_unicode_520_ci",
            supportsColumns: true),
        .init(
            id: 124, characterSet: "utf16", name57: "utf16_vietnamese_ci", name84: "utf16_vietnamese_ci",
            supportsColumns: true),
        .init(
            id: 128, characterSet: "ucs2", name57: "ucs2_unicode_ci", name84: "ucs2_unicode_ci", supportsColumns: true),
        .init(
            id: 129, characterSet: "ucs2", name57: "ucs2_icelandic_ci", name84: "ucs2_icelandic_ci",
            supportsColumns: true),
        .init(
            id: 130, characterSet: "ucs2", name57: "ucs2_latvian_ci", name84: "ucs2_latvian_ci", supportsColumns: true),
        .init(
            id: 131, characterSet: "ucs2", name57: "ucs2_romanian_ci", name84: "ucs2_romanian_ci", supportsColumns: true
        ),
        .init(
            id: 132, characterSet: "ucs2", name57: "ucs2_slovenian_ci", name84: "ucs2_slovenian_ci",
            supportsColumns: true),
        .init(id: 133, characterSet: "ucs2", name57: "ucs2_polish_ci", name84: "ucs2_polish_ci", supportsColumns: true),
        .init(
            id: 134, characterSet: "ucs2", name57: "ucs2_estonian_ci", name84: "ucs2_estonian_ci", supportsColumns: true
        ),
        .init(
            id: 135, characterSet: "ucs2", name57: "ucs2_spanish_ci", name84: "ucs2_spanish_ci", supportsColumns: true),
        .init(
            id: 136, characterSet: "ucs2", name57: "ucs2_swedish_ci", name84: "ucs2_swedish_ci", supportsColumns: true),
        .init(
            id: 137, characterSet: "ucs2", name57: "ucs2_turkish_ci", name84: "ucs2_turkish_ci", supportsColumns: true),
        .init(id: 138, characterSet: "ucs2", name57: "ucs2_czech_ci", name84: "ucs2_czech_ci", supportsColumns: true),
        .init(id: 139, characterSet: "ucs2", name57: "ucs2_danish_ci", name84: "ucs2_danish_ci", supportsColumns: true),
        .init(
            id: 140, characterSet: "ucs2", name57: "ucs2_lithuanian_ci", name84: "ucs2_lithuanian_ci",
            supportsColumns: true),
        .init(id: 141, characterSet: "ucs2", name57: "ucs2_slovak_ci", name84: "ucs2_slovak_ci", supportsColumns: true),
        .init(
            id: 142, characterSet: "ucs2", name57: "ucs2_spanish2_ci", name84: "ucs2_spanish2_ci", supportsColumns: true
        ),
        .init(id: 143, characterSet: "ucs2", name57: "ucs2_roman_ci", name84: "ucs2_roman_ci", supportsColumns: true),
        .init(
            id: 144, characterSet: "ucs2", name57: "ucs2_persian_ci", name84: "ucs2_persian_ci", supportsColumns: true),
        .init(
            id: 145, characterSet: "ucs2", name57: "ucs2_esperanto_ci", name84: "ucs2_esperanto_ci",
            supportsColumns: true),
        .init(
            id: 146, characterSet: "ucs2", name57: "ucs2_hungarian_ci", name84: "ucs2_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 147, characterSet: "ucs2", name57: "ucs2_sinhala_ci", name84: "ucs2_sinhala_ci", supportsColumns: true),
        .init(
            id: 148, characterSet: "ucs2", name57: "ucs2_german2_ci", name84: "ucs2_german2_ci", supportsColumns: true),
        .init(
            id: 149, characterSet: "ucs2", name57: "ucs2_croatian_ci", name84: "ucs2_croatian_ci", supportsColumns: true
        ),
        .init(
            id: 150, characterSet: "ucs2", name57: "ucs2_unicode_520_ci", name84: "ucs2_unicode_520_ci",
            supportsColumns: true),
        .init(
            id: 151, characterSet: "ucs2", name57: "ucs2_vietnamese_ci", name84: "ucs2_vietnamese_ci",
            supportsColumns: true),
        .init(
            id: 159, characterSet: "ucs2", name57: "ucs2_general_mysql500_ci", name84: "ucs2_general_mysql500_ci",
            supportsColumns: true),
        .init(
            id: 160, characterSet: "utf32", name57: "utf32_unicode_ci", name84: "utf32_unicode_ci",
            supportsColumns: true),
        .init(
            id: 161, characterSet: "utf32", name57: "utf32_icelandic_ci", name84: "utf32_icelandic_ci",
            supportsColumns: true),
        .init(
            id: 162, characterSet: "utf32", name57: "utf32_latvian_ci", name84: "utf32_latvian_ci",
            supportsColumns: true),
        .init(
            id: 163, characterSet: "utf32", name57: "utf32_romanian_ci", name84: "utf32_romanian_ci",
            supportsColumns: true),
        .init(
            id: 164, characterSet: "utf32", name57: "utf32_slovenian_ci", name84: "utf32_slovenian_ci",
            supportsColumns: true),
        .init(
            id: 165, characterSet: "utf32", name57: "utf32_polish_ci", name84: "utf32_polish_ci", supportsColumns: true),
        .init(
            id: 166, characterSet: "utf32", name57: "utf32_estonian_ci", name84: "utf32_estonian_ci",
            supportsColumns: true),
        .init(
            id: 167, characterSet: "utf32", name57: "utf32_spanish_ci", name84: "utf32_spanish_ci",
            supportsColumns: true),
        .init(
            id: 168, characterSet: "utf32", name57: "utf32_swedish_ci", name84: "utf32_swedish_ci",
            supportsColumns: true),
        .init(
            id: 169, characterSet: "utf32", name57: "utf32_turkish_ci", name84: "utf32_turkish_ci",
            supportsColumns: true),
        .init(
            id: 170, characterSet: "utf32", name57: "utf32_czech_ci", name84: "utf32_czech_ci", supportsColumns: true),
        .init(
            id: 171, characterSet: "utf32", name57: "utf32_danish_ci", name84: "utf32_danish_ci", supportsColumns: true),
        .init(
            id: 172, characterSet: "utf32", name57: "utf32_lithuanian_ci", name84: "utf32_lithuanian_ci",
            supportsColumns: true),
        .init(
            id: 173, characterSet: "utf32", name57: "utf32_slovak_ci", name84: "utf32_slovak_ci", supportsColumns: true),
        .init(
            id: 174, characterSet: "utf32", name57: "utf32_spanish2_ci", name84: "utf32_spanish2_ci",
            supportsColumns: true),
        .init(
            id: 175, characterSet: "utf32", name57: "utf32_roman_ci", name84: "utf32_roman_ci", supportsColumns: true),
        .init(
            id: 176, characterSet: "utf32", name57: "utf32_persian_ci", name84: "utf32_persian_ci",
            supportsColumns: true),
        .init(
            id: 177, characterSet: "utf32", name57: "utf32_esperanto_ci", name84: "utf32_esperanto_ci",
            supportsColumns: true),
        .init(
            id: 178, characterSet: "utf32", name57: "utf32_hungarian_ci", name84: "utf32_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 179, characterSet: "utf32", name57: "utf32_sinhala_ci", name84: "utf32_sinhala_ci",
            supportsColumns: true),
        .init(
            id: 180, characterSet: "utf32", name57: "utf32_german2_ci", name84: "utf32_german2_ci",
            supportsColumns: true),
        .init(
            id: 181, characterSet: "utf32", name57: "utf32_croatian_ci", name84: "utf32_croatian_ci",
            supportsColumns: true),
        .init(
            id: 182, characterSet: "utf32", name57: "utf32_unicode_520_ci", name84: "utf32_unicode_520_ci",
            supportsColumns: true),
        .init(
            id: 183, characterSet: "utf32", name57: "utf32_vietnamese_ci", name84: "utf32_vietnamese_ci",
            supportsColumns: true),
        .init(
            id: 192, characterSet: "utf8mb3", name57: "utf8_unicode_ci", name84: "utf8mb3_unicode_ci",
            supportsColumns: true),
        .init(
            id: 193, characterSet: "utf8mb3", name57: "utf8_icelandic_ci", name84: "utf8mb3_icelandic_ci",
            supportsColumns: true),
        .init(
            id: 194, characterSet: "utf8mb3", name57: "utf8_latvian_ci", name84: "utf8mb3_latvian_ci",
            supportsColumns: true),
        .init(
            id: 195, characterSet: "utf8mb3", name57: "utf8_romanian_ci", name84: "utf8mb3_romanian_ci",
            supportsColumns: true),
        .init(
            id: 196, characterSet: "utf8mb3", name57: "utf8_slovenian_ci", name84: "utf8mb3_slovenian_ci",
            supportsColumns: true),
        .init(
            id: 197, characterSet: "utf8mb3", name57: "utf8_polish_ci", name84: "utf8mb3_polish_ci",
            supportsColumns: true),
        .init(
            id: 198, characterSet: "utf8mb3", name57: "utf8_estonian_ci", name84: "utf8mb3_estonian_ci",
            supportsColumns: true),
        .init(
            id: 199, characterSet: "utf8mb3", name57: "utf8_spanish_ci", name84: "utf8mb3_spanish_ci",
            supportsColumns: true),
        .init(
            id: 200, characterSet: "utf8mb3", name57: "utf8_swedish_ci", name84: "utf8mb3_swedish_ci",
            supportsColumns: true),
        .init(
            id: 201, characterSet: "utf8mb3", name57: "utf8_turkish_ci", name84: "utf8mb3_turkish_ci",
            supportsColumns: true),
        .init(
            id: 202, characterSet: "utf8mb3", name57: "utf8_czech_ci", name84: "utf8mb3_czech_ci", supportsColumns: true
        ),
        .init(
            id: 203, characterSet: "utf8mb3", name57: "utf8_danish_ci", name84: "utf8mb3_danish_ci",
            supportsColumns: true),
        .init(
            id: 204, characterSet: "utf8mb3", name57: "utf8_lithuanian_ci", name84: "utf8mb3_lithuanian_ci",
            supportsColumns: true),
        .init(
            id: 205, characterSet: "utf8mb3", name57: "utf8_slovak_ci", name84: "utf8mb3_slovak_ci",
            supportsColumns: true),
        .init(
            id: 206, characterSet: "utf8mb3", name57: "utf8_spanish2_ci", name84: "utf8mb3_spanish2_ci",
            supportsColumns: true),
        .init(
            id: 207, characterSet: "utf8mb3", name57: "utf8_roman_ci", name84: "utf8mb3_roman_ci", supportsColumns: true
        ),
        .init(
            id: 208, characterSet: "utf8mb3", name57: "utf8_persian_ci", name84: "utf8mb3_persian_ci",
            supportsColumns: true),
        .init(
            id: 209, characterSet: "utf8mb3", name57: "utf8_esperanto_ci", name84: "utf8mb3_esperanto_ci",
            supportsColumns: true),
        .init(
            id: 210, characterSet: "utf8mb3", name57: "utf8_hungarian_ci", name84: "utf8mb3_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 211, characterSet: "utf8mb3", name57: "utf8_sinhala_ci", name84: "utf8mb3_sinhala_ci",
            supportsColumns: true),
        .init(
            id: 212, characterSet: "utf8mb3", name57: "utf8_german2_ci", name84: "utf8mb3_german2_ci",
            supportsColumns: true),
        .init(
            id: 213, characterSet: "utf8mb3", name57: "utf8_croatian_ci", name84: "utf8mb3_croatian_ci",
            supportsColumns: true),
        .init(
            id: 214, characterSet: "utf8mb3", name57: "utf8_unicode_520_ci", name84: "utf8mb3_unicode_520_ci",
            supportsColumns: true),
        .init(
            id: 215, characterSet: "utf8mb3", name57: "utf8_vietnamese_ci", name84: "utf8mb3_vietnamese_ci",
            supportsColumns: true),
        .init(
            id: 223, characterSet: "utf8mb3", name57: "utf8_general_mysql500_ci", name84: "utf8mb3_general_mysql500_ci",
            supportsColumns: true),
        .init(
            id: 224, characterSet: "utf8mb4", name57: "utf8mb4_unicode_ci", name84: "utf8mb4_unicode_ci",
            supportsColumns: true),
        .init(
            id: 225, characterSet: "utf8mb4", name57: "utf8mb4_icelandic_ci", name84: "utf8mb4_icelandic_ci",
            supportsColumns: true),
        .init(
            id: 226, characterSet: "utf8mb4", name57: "utf8mb4_latvian_ci", name84: "utf8mb4_latvian_ci",
            supportsColumns: true),
        .init(
            id: 227, characterSet: "utf8mb4", name57: "utf8mb4_romanian_ci", name84: "utf8mb4_romanian_ci",
            supportsColumns: true),
        .init(
            id: 228, characterSet: "utf8mb4", name57: "utf8mb4_slovenian_ci", name84: "utf8mb4_slovenian_ci",
            supportsColumns: true),
        .init(
            id: 229, characterSet: "utf8mb4", name57: "utf8mb4_polish_ci", name84: "utf8mb4_polish_ci",
            supportsColumns: true),
        .init(
            id: 230, characterSet: "utf8mb4", name57: "utf8mb4_estonian_ci", name84: "utf8mb4_estonian_ci",
            supportsColumns: true),
        .init(
            id: 231, characterSet: "utf8mb4", name57: "utf8mb4_spanish_ci", name84: "utf8mb4_spanish_ci",
            supportsColumns: true),
        .init(
            id: 232, characterSet: "utf8mb4", name57: "utf8mb4_swedish_ci", name84: "utf8mb4_swedish_ci",
            supportsColumns: true),
        .init(
            id: 233, characterSet: "utf8mb4", name57: "utf8mb4_turkish_ci", name84: "utf8mb4_turkish_ci",
            supportsColumns: true),
        .init(
            id: 234, characterSet: "utf8mb4", name57: "utf8mb4_czech_ci", name84: "utf8mb4_czech_ci",
            supportsColumns: true),
        .init(
            id: 235, characterSet: "utf8mb4", name57: "utf8mb4_danish_ci", name84: "utf8mb4_danish_ci",
            supportsColumns: true),
        .init(
            id: 236, characterSet: "utf8mb4", name57: "utf8mb4_lithuanian_ci", name84: "utf8mb4_lithuanian_ci",
            supportsColumns: true),
        .init(
            id: 237, characterSet: "utf8mb4", name57: "utf8mb4_slovak_ci", name84: "utf8mb4_slovak_ci",
            supportsColumns: true),
        .init(
            id: 238, characterSet: "utf8mb4", name57: "utf8mb4_spanish2_ci", name84: "utf8mb4_spanish2_ci",
            supportsColumns: true),
        .init(
            id: 239, characterSet: "utf8mb4", name57: "utf8mb4_roman_ci", name84: "utf8mb4_roman_ci",
            supportsColumns: true),
        .init(
            id: 240, characterSet: "utf8mb4", name57: "utf8mb4_persian_ci", name84: "utf8mb4_persian_ci",
            supportsColumns: true),
        .init(
            id: 241, characterSet: "utf8mb4", name57: "utf8mb4_esperanto_ci", name84: "utf8mb4_esperanto_ci",
            supportsColumns: true),
        .init(
            id: 242, characterSet: "utf8mb4", name57: "utf8mb4_hungarian_ci", name84: "utf8mb4_hungarian_ci",
            supportsColumns: true),
        .init(
            id: 243, characterSet: "utf8mb4", name57: "utf8mb4_sinhala_ci", name84: "utf8mb4_sinhala_ci",
            supportsColumns: true),
        .init(
            id: 244, characterSet: "utf8mb4", name57: "utf8mb4_german2_ci", name84: "utf8mb4_german2_ci",
            supportsColumns: true),
        .init(
            id: 245, characterSet: "utf8mb4", name57: "utf8mb4_croatian_ci", name84: "utf8mb4_croatian_ci",
            supportsColumns: true),
        .init(
            id: 246, characterSet: "utf8mb4", name57: "utf8mb4_unicode_520_ci", name84: "utf8mb4_unicode_520_ci",
            supportsColumns: true),
        .init(
            id: 247, characterSet: "utf8mb4", name57: "utf8mb4_vietnamese_ci", name84: "utf8mb4_vietnamese_ci",
            supportsColumns: true),
        .init(
            id: 248, characterSet: "gb18030", name57: "gb18030_chinese_ci", name84: "gb18030_chinese_ci",
            supportsColumns: true),
        .init(id: 249, characterSet: "gb18030", name57: "gb18030_bin", name84: "gb18030_bin", supportsColumns: true),
        .init(
            id: 250, characterSet: "gb18030", name57: "gb18030_unicode_520_ci", name84: "gb18030_unicode_520_ci",
            supportsColumns: true),
        .init(id: 255, characterSet: "utf8mb4", name57: nil, name84: "utf8mb4_0900_ai_ci", supportsColumns: false),
    ]
    /// Native CHARACTER_SETS.MAXLEN, independent of collation comparison rules.
    static func maximumBytesPerCharacter(_ charset: String) -> Int {
        widths[canonicalCharset(charset)] ?? 1
    }
    private static let widths: [String: Int] = [
        "armscii8": 1,
        "ascii": 1,
        "big5": 2,
        "binary": 1,
        "cp1250": 1,
        "cp1251": 1,
        "cp1256": 1,
        "cp1257": 1,
        "cp850": 1,
        "cp852": 1,
        "cp866": 1,
        "cp932": 2,
        "dec8": 1,
        "eucjpms": 3,
        "euckr": 2,
        "gb18030": 4,
        "gb2312": 2,
        "gbk": 2,
        "geostd8": 1,
        "greek": 1,
        "hebrew": 1,
        "hp8": 1,
        "keybcs2": 1,
        "koi8r": 1,
        "koi8u": 1,
        "latin1": 1,
        "latin2": 1,
        "latin5": 1,
        "latin7": 1,
        "macce": 1,
        "macroman": 1,
        "sjis": 2,
        "swe7": 1,
        "tis620": 1,
        "ucs2": 2,
        "ujis": 3,
        "utf16": 4,
        "utf16le": 4,
        "utf32": 4,
        "utf8mb3": 3,
        "utf8mb4": 4,
    ]
    private static let byID = Dictionary(uniqueKeysWithValues: collations.map { ($0.id, $0) })
    private static let columnsByName = Dictionary(
        uniqueKeysWithValues: collations.filter(\.supportsColumns).flatMap { entry in
            Set([entry.name84, entry.name57].compactMap { $0 }).map { ($0, entry) }
        })
    static func canonicalCharset(_ name: String) -> String { name == "utf8" ? "utf8mb3" : name }
    static func charsetName(_ name: String, on server: Server) -> String {
        canonicalCharset(name) == "utf8mb3" ? (server == .mysql57 ? "utf8" : "utf8mb3") : name
    }
    static func collationName(_ name: String, on server: Server) -> String {
        columnCollation(named: name)?.name(on: server) ?? name
    }

    static func collation(id: UInt32) -> Collation? { byID[id] }
    static func columnCollation(named name: String) -> Collation? { columnsByName[name] }

    /// Q_CHARSET uses a collation ID to identify character_set_client. Select
    /// an ID for the same encoding if the target lacks that collation. This
    /// does not map collation_connection or change comparison semantics.
    static func clientEncodingID(_ id: UInt32, target: Server) -> UInt32 {
        guard let source = byID[id], source.name(on: target) == nil,
            let available = collations.first(where: {
                $0.characterSet == source.characterSet && $0.name(on: target) != nil
            })
        else { return id }
        return available.id
    }
}
