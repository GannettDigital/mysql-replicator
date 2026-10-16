import Foundation

extension DMLCompatibilityCases {
    // Names from the pinned 5.7 COLLATIONS inventory. Keep this fixture separate
    // from the apply registry so a missing registry entry cannot remove its test.
    static let characterCollations: Case = {
        let collations: [(Int, String, String)] = [
            (5, "latin1", "latin1_german1_ci"),
            (8, "latin1", "latin1_swedish_ci"),
            (11, "ascii", "ascii_general_ci"),
            (15, "latin1", "latin1_danish_ci"),
            (31, "latin1", "latin1_german2_ci"),
            (33, "utf8", "utf8_general_ci"),
            (45, "utf8mb4", "utf8mb4_general_ci"),
            (46, "utf8mb4", "utf8mb4_bin"),
            (47, "latin1", "latin1_bin"),
            (48, "latin1", "latin1_general_ci"),
            (49, "latin1", "latin1_general_cs"),
            (65, "ascii", "ascii_bin"),
            (83, "utf8", "utf8_bin"),
            (94, "latin1", "latin1_spanish_ci"),
            (192, "utf8", "utf8_unicode_ci"),
            (193, "utf8", "utf8_icelandic_ci"),
            (194, "utf8", "utf8_latvian_ci"),
            (195, "utf8", "utf8_romanian_ci"),
            (196, "utf8", "utf8_slovenian_ci"),
            (197, "utf8", "utf8_polish_ci"),
            (198, "utf8", "utf8_estonian_ci"),
            (199, "utf8", "utf8_spanish_ci"),
            (200, "utf8", "utf8_swedish_ci"),
            (201, "utf8", "utf8_turkish_ci"),
            (202, "utf8", "utf8_czech_ci"),
            (203, "utf8", "utf8_danish_ci"),
            (204, "utf8", "utf8_lithuanian_ci"),
            (205, "utf8", "utf8_slovak_ci"),
            (206, "utf8", "utf8_spanish2_ci"),
            (207, "utf8", "utf8_roman_ci"),
            (208, "utf8", "utf8_persian_ci"),
            (209, "utf8", "utf8_esperanto_ci"),
            (210, "utf8", "utf8_hungarian_ci"),
            (211, "utf8", "utf8_sinhala_ci"),
            (212, "utf8", "utf8_german2_ci"),
            (213, "utf8", "utf8_croatian_ci"),
            (214, "utf8", "utf8_unicode_520_ci"),
            (215, "utf8", "utf8_vietnamese_ci"),
            (223, "utf8", "utf8_general_mysql500_ci"),
            (224, "utf8mb4", "utf8mb4_unicode_ci"),
            (225, "utf8mb4", "utf8mb4_icelandic_ci"),
            (226, "utf8mb4", "utf8mb4_latvian_ci"),
            (227, "utf8mb4", "utf8mb4_romanian_ci"),
            (228, "utf8mb4", "utf8mb4_slovenian_ci"),
            (229, "utf8mb4", "utf8mb4_polish_ci"),
            (230, "utf8mb4", "utf8mb4_estonian_ci"),
            (231, "utf8mb4", "utf8mb4_spanish_ci"),
            (232, "utf8mb4", "utf8mb4_swedish_ci"),
            (233, "utf8mb4", "utf8mb4_turkish_ci"),
            (234, "utf8mb4", "utf8mb4_czech_ci"),
            (235, "utf8mb4", "utf8mb4_danish_ci"),
            (236, "utf8mb4", "utf8mb4_lithuanian_ci"),
            (237, "utf8mb4", "utf8mb4_slovak_ci"),
            (238, "utf8mb4", "utf8mb4_spanish2_ci"),
            (239, "utf8mb4", "utf8mb4_roman_ci"),
            (240, "utf8mb4", "utf8mb4_persian_ci"),
            (241, "utf8mb4", "utf8mb4_esperanto_ci"),
            (242, "utf8mb4", "utf8mb4_hungarian_ci"),
            (243, "utf8mb4", "utf8mb4_sinhala_ci"),
            (244, "utf8mb4", "utf8mb4_german2_ci"),
            (245, "utf8mb4", "utf8mb4_croatian_ci"),
            (246, "utf8mb4", "utf8mb4_unicode_520_ci"),
            (247, "utf8mb4", "utf8mb4_vietnamese_ci"),
        ]
        let columns = collations.map { "c\($0.0)" }
        let values = collations.map { _, charset, _ in
            charset == "ascii"
                ? "CONVERT(0x410020 USING ascii)"
                : charset == "latin1"
                    ? "CONVERT(0xE900FF20 USING latin1)" : "CONVERT(0xC3A9E4B8AD0020 USING \(charset))"
        }
        let expected = collations.map { id, charset, _ in
            "HEX(c\(id))='\(charset == "ascii" ? "410020" : charset == "latin1" ? "E900FF20" : "C3A9E4B8AD0020")'"
        }.joined(separator: " AND ")
        let definition =
            "id VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci PRIMARY KEY,"
            + collations.map { id, charset, name in
                "c\(id) VARCHAR(12) CHARACTER SET \(charset) COLLATE \(name) DEFAULT 'A'"
            }.joined(separator: ",")
        return Case(
            id: "collations", definition: definition,
            phases: [
                .init(
                    sql: "INSERT INTO poc.matrix_collations(id) VALUES('first'),('second')",
                    check: "SELECT COUNT(*)=2 AND SUM(c5='A')=2 AND SUM(c247='A')=2 FROM poc.matrix_collations"),
                .init(
                    sql: "UPDATE poc.matrix_collations SET id='FirstX',"
                        + zip(columns, values).map { "\($0)=\($1)" }.joined(separator: ",") + " WHERE id='FIRST'",
                    check: "SELECT COUNT(*)=1 FROM poc.matrix_collations WHERE id='firstx' AND " + expected),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_collations MODIFY c49 VARCHAR(12) CHARACTER SET latin1 COLLATE latin1_spanish_ci DEFAULT 'A'; UPDATE poc.matrix_collations SET c49=NULL WHERE id='second'",
                    check: "SELECT COUNT(*)=1 FROM poc.matrix_collations WHERE id='second' AND c49 IS NULL"),
                .init(
                    sql: "DELETE FROM poc.matrix_collations WHERE id='FIRSTX'",
                    check: "SELECT COUNT(*)=1 AND MIN(id)='second' AND SUM(c49 IS NULL)=1 FROM poc.matrix_collations"),
            ])
    }()
}
