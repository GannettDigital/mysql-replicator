import Foundation
import XCTest

@testable import ReplicatorLabCore

final class WideChoicesWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case {
        DMLCompatibilityCases.cases.first { $0.id == "widechoices" }!
    }
    private let allBitsHex =
        "73312C73322C73332C73342C73352C73362C73372C73382C73392C7331302C7331312C7331322C7331332C7331342C7331352C7331362C7331372C7331382C7331392C7332302C7332312C7332322C7332332C7332342C7332352C7332362C7332372C7332382C7332392C7333302C7333312C7333322C7333332C7333342C7333352C7333362C7333372C7333382C7333392C7334302C7334312C7334322C7334332C7334342C7334352C7334362C7334372C7334382C7334392C7335302C7335312C7335322C7335332C7335342C7335352C7335362C7335372C7335382C7335392C7336302C7336312C7336322C7336332C733634"
    private let originalSQL = [
        "INSERT INTO poc.matrix_widechoices VALUES(1,256,18446744073709551615)",
        "UPDATE poc.matrix_widechoices SET e=255,s=9223372036854775808 WHERE id=1",
        "DELETE FROM poc.matrix_widechoices WHERE id=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=1 FROM poc.matrix_widechoices WHERE e+0=256 AND CAST(s AS UNSIGNED)=18446744073709551615",
        "SELECT COUNT(*)=1 FROM poc.matrix_widechoices WHERE e+0=255 AND CAST(s AS UNSIGNED)=9223372036854775808",
        "SELECT COUNT(*)=0 FROM poc.matrix_widechoices",
    ]
    private let projection =
        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL') FROM poc."
    private var definition: String {
        "id INT PRIMARY KEY,e ENUM(" + (1...256).map { "'e\($0)'" }.joined(separator: ",")
            + "),s SET(" + (1...64).map { "'s\($0)'" }.joined(separator: ",") + ")"
    }

    func testCompleteDefinitionsOriginalScriptsAndColdMetadataRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertTrue(fixture.definition.contains("'e255','e256')"))
        XCTAssertTrue(fixture.definition.hasSuffix("'s63','s64')"))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.rowMetadata, "FULL")
        XCTAssertEqual(fixture.orderBy, "id")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
            XCTAssertTrue(fixture.applies(to: profile))
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile).first {
                    $0.id == "widechoices"
                })
            XCTAssertEqual(Data(cold.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(cold.phases[0].sql, originalSQL[0])
            XCTAssertEqual(cold.phases[0].check, originalChecks[0])
            XCTAssertEqual(cold.rowMetadata, "FULL")
        }
    }

    func testBatchesKeepOriginalOrderSessionsAndCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["matrix_widechoices", "wc_after_insert", "wc_after_update"]
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            tables.map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactions, [1, 1, 1])
        XCTAssertEqual(plan.body.transactions, [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 3)
        XCTAssertEqual(plan.expectedRows, 6)
        let expected =
            originalSQL.map { "USE poc; " + $0 }
            + [
                "USE poc; "
                    + originalSQL[0].replacingOccurrences(of: "poc.matrix_widechoices", with: "poc.wc_after_insert")
            ]
            + originalSQL.prefix(2).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_widechoices", with: "poc.wc_after_update")
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

    func testAllOldPredicatesKeepSQLAndExpectedResults() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["wc_after_insert", "wc_after_update", "matrix_widechoices"]
        for (index, sql) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql, sql.replacingOccurrences(of: "poc.matrix_widechoices", with: "poc." + tables[index]))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testFixedRowsKeepFullUnsignedValuesAndBoundaryLabels() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let maximum = "18446744073709551615"
        let highBit = "9223372036854775808"
        XCTAssertEqual(UInt64(maximum), UInt64.max)
        XCTAssertEqual(UInt64(highBit), UInt64(1) << 63)
        XCTAssertEqual(allBitsHex.count, 492)
        XCTAssertEqual(
            allBitsHex,
            (1...64).map { "s\($0)" }.joined(separator: ",").utf8.map { String(format: "%02X", $0) }.joined())
        for (id, table, value) in [
            ("initial-row", "wc_after_insert", "1\t256\t65323536\t" + maximum + "\t" + allBitsHex),
            ("updated-row", "wc_after_update", "1\t255\t65323535\t" + highBit + "\t733634"),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            XCTAssertEqual(check.check.sql, projection + table + " ORDER BY id")
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(
                    try check.result(
                        [
                            id: value.replacingOccurrences(of: maximum, with: "-1").replacingOccurrences(
                                of: highBit, with: "-9223372036854775808")
                        ], engine: engine, role: "target"))
                XCTAssertThrowsError(
                    try check.result(
                        [
                            id: value.replacingOccurrences(of: "65323536", with: "65323535").replacingOccurrences(
                                of: "65323535", with: "65323534")
                        ], engine: engine, role: "target"))
                XCTAssertThrowsError(try check.result([id: value + "00"], engine: engine, role: "target"))
            }
        }
        let empty = try XCTUnwrap(plan.final.checks.first { $0.id == "empty-final-table" })
        XCTAssertEqual(empty.check.sql, projection + "matrix_widechoices ORDER BY id")
        XCTAssertEqual(empty.check.expected, "")
        _ = try empty.result([empty.id: ""], engine: "MyISAM", role: "target")
        XCTAssertThrowsError(try empty.result([empty.id: "0"], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try empty.result([empty.id: "1\t255\t65323535\t" + highBit + "\t733634"], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testCheckpointCountersAndPositionsIncludeCleanup() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 10, "ddlApplied": 4, "rowsApplied": 7]
        let end = Boundary(file: "binlog.000003", position: 1000, gtids: "uuid:1-19")
        var after: [String: Any] = [
            "transactionsApplied": 19, "ddlApplied": 7, "rowsApplied": 13, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "1000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 12
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 13
        let cleanup = Boundary(file: end.file, position: 1200, gtids: "uuid:1-20")
        after["transactionsApplied"] = 20
        after["ddlApplied"] = 8
        after["appliedGTIDSet"] = cleanup.gtids
        after["appliedPosition"] = ["file": cleanup.file, "position": "1200"]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleanup, cleaned: true))
        after["appliedPosition"] = ["file": cleanup.file, "position": "1000"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: cleanup, cleaned: true))
    }

    func testCleanupTitleAndOtherChoiceCasesStayUnchanged() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 6)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.wc_after_insert,poc.wc_after_update"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM and SET: two-byte ENUM ordinals and 64-bit SET values")
        XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-widechoices" }?.test.name, fixture.displayName)
        for id in ["legacybinaryset", "exactchoices", "enumzero", "choiceboundaries"] {
            XCTAssertNil(try XCTUnwrap(DMLCompatibilityCases.cases.first { $0.id == id }).workflow, id)
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "binarychoices", "identifiercase", "unicodeidentifiers", "choices",
                "widechoices",
            ])
    }
}
