import Foundation
import XCTest

@testable import ReplicatorLabCore

final class ChoiceBoundariesWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.choiceBoundaries }
    private var definition: String {
        #"id INT PRIMARY KEY,e ENUM('','a  ','it''s','a\\b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'a',w ENUM('†','中') CHARACTER SET utf16le COLLATE utf16le_bin DEFAULT '†',s SET('†','中') CHARACTER SET utf32 COLLATE utf32_bin DEFAULT '中,†',g ENUM('😀','?') CHARACTER SET gb18030 COLLATE gb18030_bin DEFAULT '😀',bits SET("#
            + (1...64).map { "'s\($0)'" }.joined(separator: ",") + ") DEFAULT 's64'"
    }
    private let originalSQL = [
        "INSERT INTO poc.matrix_choiceboundaries VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT),(2,1,2,0,2,18446744073709551615),(3,NULL,NULL,NULL,NULL,NULL)",
        "UPDATE poc.matrix_choiceboundaries SET e=4,w=2,s=2,bits=1 WHERE id=2",
        "DELETE FROM poc.matrix_choiceboundaries WHERE id=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=1 FROM poc.matrix_choiceboundaries WHERE id=1 AND e+0=2 AND HEX(e)='61' AND HEX(w)='2020' AND s+0=3 AND HEX(s)='000020200000002C00004E2D' AND HEX(g)='9439FC36' AND CAST(bits AS UNSIGNED)=9223372036854775808",
        "SELECT COUNT(*)=1 FROM poc.matrix_choiceboundaries WHERE id=2 AND HEX(e)='615C62' AND HEX(w)='2D4E' AND HEX(s)='00004E2D' AND bits+0=1",
        "SELECT COUNT(*)=2 AND SUM(id=2 AND e+0=4)=1 AND SUM(id=3 AND e IS NULL)=1 FROM poc.matrix_choiceboundaries",
    ]
    private let projection =
        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(g+0,'NULL'),IFNULL(HEX(g),'NULL'),IFNULL(CAST(bits AS UNSIGNED),'NULL'),IFNULL(HEX(bits),'NULL')"
    private let defaultRow = "1\t2\t61\t1\t2020\t3\t000020200000002C00004E2D\t1\t9439FC36\t9223372036854775808\t733634"
    private let changedRow = "2\t4\t615C62\t2\t2D4E\t2\t00004E2D\t2\t3F\t1\t7331"
    private let nullRow = "3\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
    private var allBitsHex: String {
        (1...64).map { "s\($0)" }.joined(separator: ",").utf8.map { String(format: "%02X", $0) }.joined()
    }
    private var initialRows: String {
        defaultRow + "\n2\t1\t\t2\t2D4E\t0\t\t2\t3F\t18446744073709551615\t" + allBitsHex + "\n" + nullRow
    }

    func testOriginalEscapedDefinitionScriptsAndColdMetadataRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertTrue(definition.contains("'a  ','it''s'"))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.orderBy, "id")
        XCTAssertEqual(fixture.rowMetadata, "FULL")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
            XCTAssertTrue(fixture.applies(to: profile))
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(cold.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(cold.phases[0].sql, originalSQL[0])
            XCTAssertEqual(cold.phases[0].check, originalChecks[0])
            XCTAssertEqual(cold.rowMetadata, "FULL")
        }
    }

    func testBatchesKeepOriginalRequestsSessionsAndCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            ["matrix_choiceboundaries", "cb_after_insert", "cb_after_update"].map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (count, table) in [(1, "cb_after_insert"), (2, "cb_after_update")] {
            expected += originalSQL.prefix(count).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_choiceboundaries", with: "poc." + table)
            }
        }
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.prepare.transactions, [1, 1, 1])
        XCTAssertEqual(plan.body.transactions, [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 3)
        XCTAssertEqual(plan.expectedRows, 12)
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

    func testEveryOriginalPredicateRemainsOnItsMatchingResult() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (index, table) in ["cb_after_insert", "cb_after_update", "matrix_choiceboundaries"].enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalChecks[index].replacingOccurrences(of: "poc.matrix_choiceboundaries", with: "poc." + table))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testCompleteRowsKeepEncodedBytesEmptyFieldsNullAndUnsignedMasks() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(UInt64("18446744073709551615"), UInt64.max)
        XCTAssertEqual(UInt64("9223372036854775808"), UInt64(1) << 63)
        XCTAssertEqual(allBitsHex.count, 492)
        for (id, table, expected) in [
            ("initial-rows", "cb_after_insert", initialRows),
            ("updated-rows", "cb_after_update", defaultRow + "\n" + changedRow + "\n" + nullRow),
            ("final-rows", "matrix_choiceboundaries", changedRow + "\n" + nullRow),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.sql, projection + " FROM poc." + table + " ORDER BY id")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(expected.utf8))
            XCTAssertTrue(
                expected.split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == 11
                })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: expected], engine: engine, role: "target")
                for (old, wrong) in [
                    ("2D4E", "4E2D"), ("00004E2D", "E4B8AD"), ("NULL", ""),
                    ("9439FC36", "F09F9880"), ("615C62", "615C5C62"),
                    ("18446744073709551615", "-1"), ("9223372036854775808", "-9223372036854775808"),
                    ("\t\t", "\t"),
                ] where expected.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [id: expected.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
        let final = try XCTUnwrap(plan.final.checks.first { $0.id == "final-rows" })
        XCTAssertThrowsError(try final.result([final.id: initialRows], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testDefaultsUseTrimmedLabelsDeclaredSETOrderAndNativeEncodings() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let check = try XCTUnwrap(plan.final.checks.first { $0.id == "default-bytes" })
        XCTAssertEqual(
            check.check.sql,
            "SELECT HEX(DEFAULT(e)),HEX(DEFAULT(w)),HEX(DEFAULT(s)),HEX(DEFAULT(g)),HEX(DEFAULT(bits)) FROM poc.cb_after_insert WHERE id=1"
        )
        XCTAssertEqual(check.check.expected, "61\t2020\t000020200000002C00004E2D\t9439FC36\t733634")
        _ = try check.result([check.id: check.check.expected], engine: "MyISAM", role: "target")
        for (old, wrong) in [
            ("61\t", "612020\t"), ("000020200000002C00004E2D", "00004E2D0000002C00002020"),
            ("9439FC36", "3F"), ("733634", "733633"),
        ] {
            XCTAssertThrowsError(
                try check.result(
                    [check.id: check.check.expected.replacingOccurrences(of: old, with: wrong)], engine: "MyISAM",
                    role: "target"))
        }
    }

    func testCheckpointsIncludeExactCountersAndCleanupPosition() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
        let end = Boundary(file: "binlog.000001", position: 1000, gtids: "uuid:1-11")
        var after: [String: Any] = [
            "transactionsApplied": 11, "ddlApplied": 4, "rowsApplied": 15, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "1000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 14
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 15
        let cleaned = Boundary(file: end.file, position: 1100, gtids: "uuid:1-12")
        after["transactionsApplied"] = 12
        after["ddlApplied"] = 5
        after["appliedGTIDSet"] = cleaned.gtids
        after["appliedPosition"] = ["file": cleaned.file, "position": "1100"]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
        after["appliedPosition"] = ["file": cleaned.file, "position": "1000"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
    }

    func testCleanupTitleAndChoiceCasesStayExplicit() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 7)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.cb_after_insert,poc.cb_after_update"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM and SET: trimmed labels, escapes and multibyte boundaries")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-choiceboundaries" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "zerowidth", "identifiercase", "unicodeidentifiers", "encodings", "widestrings",
                "bits", "enumzero", "choices", "widechoices", "integers", "decimal",
            ])
    }
}
