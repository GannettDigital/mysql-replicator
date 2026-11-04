import Foundation
import XCTest

@testable import ReplicatorLabCore

final class NativeEncodingWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.nativeEncodings }
    // Fixed native IDs and bytes; no production registry or converter is used.
    private let inventory = """
        armscii8 armscii8_bin 64 B20020 B200 41
        big5 big5_bin 84 A4A40020 A4A400 41
        cp1250 cp1250_polish_ci 99 C00020 C000 41
        cp1251 cp1251_general_cs 52 C00020 C000 41
        cp1256 cp1256_bin 67 C10020 C100 41
        cp1257 cp1257_general_ci 59 C00020 C000 41
        cp850 cp850_bin 80 820020 8200 41
        cp852 cp852_bin 81 800020 8000 41
        cp866 cp866_bin 68 800020 8000 41
        cp932 cp932_bin 96 82A00020 82A000 41
        dec8 dec8_bin 69 C40020 C400 41
        eucjpms eucjpms_bin 98 A4A20020 A4A200 41
        euckr euckr_bin 85 B0A10020 B0A100 41
        gb18030 gb18030_unicode_520_ci 250 D6D00020 D6D000 41
        gb2312 gb2312_bin 86 D6D00020 D6D000 41
        gbk gbk_bin 87 D6D00020 D6D000 41
        geostd8 geostd8_bin 93 C00020 C000 41
        greek greek_bin 70 C10020 C100 41
        hebrew hebrew_bin 71 E00020 E000 41
        hp8 hp8_bin 72 C40020 C400 41
        keybcs2 keybcs2_bin 73 800020 8000 41
        koi8r koi8r_bin 74 C10020 C100 41
        koi8u koi8u_bin 75 C10020 C100 41
        latin2 latin2_bin 77 A10020 A100 41
        latin5 latin5_bin 78 D00020 D000 41
        latin7 latin7_bin 79 C00020 C000 41
        macce macce_bin 43 800020 8000 41
        macroman macroman_bin 53 800020 8000 41
        sjis sjis_bin 88 82A00020 82A000 41
        swe7 swe7_bin 82 5B0020 5B00 41
        tis620 tis620_bin 89 A10020 A100 41
        ucs2 ucs2_general_mysql500_ci 159 202000000020 20200000 0041
        ujis ujis_bin 91 A4A20020 A4A200 41
        utf16 utf16_vietnamese_ci 124 D83DDE00202000000020 D83DDE0020200000 0041
        utf16le utf16le_bin 62 0020202000002000 002020200000 4100
        utf32 utf32_vietnamese_ci 183 000020200000000000000020 0000202000000000 00000041
        """
    private var members: [(charset: String, collation: String, id: Int, full: String, trimmed: String, initial: String)]
    {
        inventory.split(separator: "\n").map {
            let fields = $0.split(separator: " ").map(String.init)
            return (fields[0], fields[1], Int(fields[2])!, fields[3], fields[4], fields[5])
        }
    }
    private var names: [String] {
        members.flatMap { e in ["c_" + e.charset, "v_" + e.charset, "t_" + e.charset] }
    }
    private var originalDefinition: String {
        let fields = members.flatMap { e in
            [
                "c_\(e.charset) CHAR(4) CHARACTER SET \(e.charset) COLLATE \(e.collation) DEFAULT 'A'",
                "v_\(e.charset) VARCHAR(12) CHARACTER SET \(e.charset) COLLATE \(e.collation)",
                "t_\(e.charset) TEXT CHARACTER SET \(e.charset) COLLATE \(e.collation)",
            ]
        }
        return "id VARCHAR(12) CHARACTER SET utf16 COLLATE utf16_bin PRIMARY KEY," + fields.joined(separator: ",")
    }
    private var originalSQL: [String] {
        let values = members.flatMap { e in Array(repeating: "CONVERT(0x\(e.full) USING \(e.charset))", count: 3) }
        return [
            "INSERT INTO poc.matrix_nativeencodings(id) VALUES('first'),('second')",
            "UPDATE poc.matrix_nativeencodings SET id='changed',"
                + zip(names, values).map { $0 + "=" + $1 }.joined(separator: ",") + " WHERE id='first'",
            "ALTER TABLE poc.matrix_nativeencodings ADD extra VARCHAR(4) CHARACTER SET gb18030 COLLATE gb18030_bin; UPDATE poc.matrix_nativeencodings SET "
                + names.map { $0 + "=NULL" }.joined(separator: ",")
                + ",extra=CONVERT(0x9439FC36 USING gb18030) WHERE id='second'",
            "DELETE FROM poc.matrix_nativeencodings WHERE id='changed'",
        ]
    }
    private var originalChecks: [String] {
        let vectors = members.flatMap { e in
            [
                "HEX(c_\(e.charset))='\(e.trimmed)'", "HEX(v_\(e.charset))='\(e.full)'",
                "HEX(t_\(e.charset))='\(e.full)'",
            ]
        }
        return [
            "SELECT COUNT(*)=2 AND SUM(HEX(c_ucs2)='0041')=2 AND SUM(HEX(c_utf32)='00000041')=2 FROM poc.matrix_nativeencodings",
            "SELECT COUNT(*)=1 FROM poc.matrix_nativeencodings WHERE id='changed' AND "
                + vectors.joined(separator: " AND "),
            "SELECT COUNT(*)=1 FROM poc.matrix_nativeencodings WHERE id='second' AND c_ucs2 IS NULL AND t_big5 IS NULL AND HEX(extra)='9439FC36'",
            "SELECT COUNT(*)=1 AND MIN(id)='second' FROM poc.matrix_nativeencodings",
        ]
    }

    func testAllOriginalVectorsScriptsAndMetadataInputsRemain() throws {
        XCTAssertEqual(members.count, 36)
        XCTAssertEqual(Set(members.map(\.charset)).count, 36)
        XCTAssertEqual(names.count, 108)
        XCTAssertEqual(Data(fixture.definition.utf8), Data(originalDefinition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map { Data($0.check.utf8) }, originalChecks.map { Data($0.utf8) })
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
            let metadata = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(metadata.definition.utf8), Data(originalDefinition.utf8))
            XCTAssertEqual(metadata.phases[0].sql, originalSQL[0])
            XCTAssertEqual(metadata.phases[0].check, originalChecks[0])
        }
    }

    func testBatchesKeepScriptsSessionsAndGTIDCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["matrix_nativeencodings", "ne_after_insert", "ne_after_update", "ne_after_add"]
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            tables.map {
                "CREATE TABLE poc." + $0 + "(" + originalDefinition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.transactions, [1, 1, 2, 1, 1, 1, 1, 1, 1, 2])
        XCTAssertEqual(plan.body.transactionCount, 12)
        XCTAssertEqual(plan.expectedDDL, 6)
        XCTAssertEqual(plan.expectedRows, 14)
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (length, table) in [(1, "ne_after_insert"), (2, "ne_after_update"), (3, "ne_after_add")] {
            expected += originalSQL.prefix(length).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_nativeencodings", with: "poc." + table)
            }
        }
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        for batch in [plan.prepare, plan.body, plan.cleanup] {
            let queries = try LabSQLPhase.queries(
                batch.writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
            for (index, write) in batch.writes.enumerated() {
                XCTAssertTrue(queries[index * 4].sql.hasPrefix(LabProfile.forward.session))
                XCTAssertTrue(queries[index * 4].sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                XCTAssertFalse(write.sql.contains("BEGIN"))
                XCTAssertFalse(write.sql.contains("COMMIT"))
            }
        }
    }

    func testFourOriginalPredicatesKeepTheirSQLAndExpectedResults() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["ne_after_insert", "ne_after_update", "ne_after_add", "matrix_nativeencodings"]
        for (index, sql) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                sql.replacingOccurrences(of: "poc.matrix_nativeencodings", with: "poc." + tables[index]))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testFullRowsKeepAllBytesTrimmingDefaultsNullsAndUTF16Keys() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let initial = members.flatMap { [$0.initial, "NULL", "NULL"] }
        let updated = members.flatMap { [$0.trimmed, $0.full, $0.full] }
        let cleared = Array(repeating: "NULL", count: 108)
        let first = ["00660069007200730074"] + initial
        let second = ["007300650063006F006E0064"] + initial
        let changed = ["006300680061006E006700650064"] + updated
        let afterNull = ["007300650063006F006E0064"] + cleared + ["9439FC36"]
        let expected: [(String, String, [[String]], Bool)] = [
            ("initial-rows", "ne_after_insert", [first, second], false),
            ("updated-rows", "ne_after_update", [changed, second], false),
            ("added-column-rows", "ne_after_add", [changed + ["NULL"], afterNull], true),
            ("surviving-row", "matrix_nativeencodings", [afterNull], true),
        ]
        for (id, table, rows, added) in expected {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            let value = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            let fields = ["HEX(id)"] + (names + (added ? ["extra"] : [])).map { "IFNULL(HEX(\($0)),'NULL')" }
            XCTAssertEqual(
                check.check.sql,
                "SELECT " + fields.joined(separator: ",") + " FROM poc." + table + " ORDER BY BINARY id")
            XCTAssertTrue(rows.allSatisfy { $0.count == (added ? 110 : 109) })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(
                    try check.result(
                        [id: rows.map { $0.dropLast().joined(separator: "\t") }.joined(separator: "\n")],
                        engine: engine, role: "target"))
            }
        }
        let updatedCheck = try XCTUnwrap(plan.final.checks.first { $0.id == "updated-rows" })
        for (index, e) in members.enumerated() {
            XCTAssertNotEqual(e.trimmed, e.full, e.charset)
            var wrong = changed
            wrong[1 + index * 3] = e.full
            let value = [wrong, second].map { $0.joined(separator: "\t") }.joined(separator: "\n")
            XCTAssertThrowsError(
                try updatedCheck.result([updatedCheck.id: value], engine: "MyISAM", role: "target"), e.charset)
        }
        let addedCheck = try XCTUnwrap(plan.final.checks.first { $0.id == "added-column-rows" })
        XCTAssertThrowsError(
            try addedCheck.result(
                [addedCheck.id: addedCheck.check.expected.replacingOccurrences(of: "9439FC36", with: "D6D00020")],
                engine: "MyISAM", role: "target"))
    }

    func testMetadataChecksEveryColumnKindKeyAndAddedCollation() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let originals =
            ["id\t55\tutf16\tutf16_bin"]
            + members.flatMap { e in
                ["c_", "v_", "t_"].map { "\($0)\(e.charset)\t\(e.id)\t\(e.charset)\t\(e.collation)" }
            }
        for (id, table, added) in [
            ("original-character-set-ids", "ne_after_update", false), ("added-character-set-ids", "ne_after_add", true),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            let expected = (originals + (added ? ["extra\t249\tgb18030\tgb18030_bin"] : [])).joined(separator: "\n")
            XCTAssertEqual(check.check.expected, expected)
            XCTAssertTrue(check.check.sql.hasPrefix("SELECT c.COLUMN_NAME,k.ID,c.CHARACTER_SET_NAME,c.COLLATION_NAME"))
            XCTAssertTrue(
                check.check.sql.contains("JOIN information_schema.COLLATIONS k ON k.COLLATION_NAME=c.COLLATION_NAME"))
            XCTAssertTrue(check.check.sql.hasSuffix("c.TABLE_NAME='\(table)' ORDER BY c.ORDINAL_POSITION"))
            _ = try check.result([id: expected], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(
                try check.result(
                    [
                        id: expected.replacingOccurrences(
                            of: "id\t55\tutf16\tutf16_bin", with: "id\t124\tutf16\tutf16_vietnamese_ci")
                    ], engine: "MyISAM", role: "target"))
            XCTAssertThrowsError(
                try check.result(
                    [id: expected.replacingOccurrences(of: "t_armscii8\t64\tarmscii8\tarmscii8_bin\n", with: "")],
                    engine: "MyISAM", role: "target"))
            if added {
                XCTAssertThrowsError(
                    try check.result(
                        [
                            id: expected.replacingOccurrences(
                                of: "extra\t249\tgb18030\tgb18030_bin",
                                with: "extra\t250\tgb18030\tgb18030_unicode_520_ci")
                        ], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testCleanupKeepsOriginalTableAndTitleMatchesInventory() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.final.checks.count, 10)
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ne_after_insert,poc.ne_after_update,poc.ne_after_add"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(fixture.displayName, "Character sets: CHAR, VARCHAR and TEXT byte values and multibyte keys")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-nativeencodings" }?.test.name, fixture.displayName)
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertTrue(plan.final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "identifiercase",
                "unicodeidentifiers", "enumzero", "choices",
                "widechoices",
            ])
    }
}
