import Foundation
import XCTest

@testable import ReplicatorLabCore

final class ChoicesWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case {
        DMLCompatibilityCases.cases.first { $0.id == "choices" }!
    }
    private let definition = "id INT PRIMARY KEY,e ENUM('','one','it''s','x,y','é'),s SET('a','b','c')"
    private let originalSQL = [
        "INSERT INTO poc.matrix_choices VALUES(1,1,0),(2,2,7),(3,'it''s','a,c'),(4,NULL,NULL),(5,'é','b')",
        "UPDATE poc.matrix_choices SET e='x,y',s=6 WHERE id=3",
        "DELETE FROM poc.matrix_choices WHERE id IN (1,2,3,5)",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=1 AND e+0=1 AND s+0=0",
        "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=3 AND e+0=4 AND s+0=6",
        "SELECT COUNT(*)=1 FROM poc.matrix_choices WHERE id=4 AND e IS NULL",
    ]
    private let initialRows =
        "1\t1\t\t0\t\n2\t2\t6F6E65\t7\t612C622C63\n3\t3\t69742773\t5\t612C63\n4\tNULL\tNULL\tNULL\tNULL\n5\t5\tC3A9\t2\t62"
    private let updatedRows =
        "1\t1\t\t0\t\n2\t2\t6F6E65\t7\t612C622C63\n3\t4\t782C79\t6\t622C63\n4\tNULL\tNULL\tNULL\tNULL\n5\t5\tC3A9\t2\t62"
    private let projection =
        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL') FROM poc."

    func testOriginalDefinitionScriptsAndMetadataInputsRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
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
                    $0.id == "choices"
                })
            XCTAssertEqual(Data(cold.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(cold.phases[0].sql, originalSQL[0])
            XCTAssertEqual(cold.phases[0].check, originalChecks[0])
            XCTAssertEqual(cold.rowMetadata, "FULL")
        }
    }

    func testBatchesKeepExactRequestsSessionsAndThreePhaseCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["matrix_choices", "ch_after_insert", "ch_after_update"]
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            tables.map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactions, [1, 1, 1])
        XCTAssertEqual(plan.body.transactions, [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 3)
        XCTAssertEqual(plan.expectedRows, 21)
        let expected =
            originalSQL.map { "USE poc; " + $0 }
            + ["USE poc; " + originalSQL[0].replacingOccurrences(of: "poc.matrix_choices", with: "poc.ch_after_insert")]
            + originalSQL.prefix(2).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_choices", with: "poc.ch_after_update")
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
        XCTAssertTrue(plan.prepare.writes.allSatisfy { !$0.sql.contains("USE ") })
        XCTAssertTrue(plan.body.writes.allSatisfy { $0.sql.hasPrefix("USE poc; ") })
    }

    func testAllThreeOldPredicatesKeepTheirSQLAndExpectedValues() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["ch_after_insert", "ch_after_update", "matrix_choices"]
        for (index, sql) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql, sql.replacingOccurrences(of: "poc.matrix_choices", with: "poc." + tables[index]))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testFullRowsRetainLiteralsOrdinalsMasksEmptyFieldsAndNulls() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, table, expected) in [
            ("initial-rows", "ch_after_insert", initialRows),
            ("updated-rows", "ch_after_update", updatedRows),
            ("final-row", "matrix_choices", "4\tNULL\tNULL\tNULL\tNULL"),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(Data(check.check.expected.utf8), Data(expected.utf8))
            XCTAssertEqual(check.check.sql, projection + table + " ORDER BY id")
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: expected], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([id: expected + "\n6\t1\t\t0\t"], engine: engine, role: "target"))
            }
            let fields = expected.split(separator: "\n").map {
                $0.split(separator: "\t", omittingEmptySubsequences: false)
            }
            XCTAssertTrue(fields.allSatisfy { $0.count == 5 })
        }
        let check = try XCTUnwrap(plan.final.checks.first { $0.id == "initial-rows" })
        // Ordinal zero has the same empty display bytes as declared member one.
        XCTAssertThrowsError(
            try check.result(
                [check.id: initialRows.replacingOccurrences(of: "1\t1\t\t0\t", with: "1\t0\t\t0\t")], engine: "MyISAM",
                role: "target"))
        XCTAssertThrowsError(
            try check.result(
                [check.id: initialRows.replacingOccurrences(of: "\t\n", with: "\n")], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try check.result(
                [check.id: initialRows.replacingOccurrences(of: "C3A9", with: "E9")], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try check.result(
                [check.id: initialRows.replacingOccurrences(of: "NULL", with: "")], engine: "MyISAM", role: "target"))
        let changed = try XCTUnwrap(plan.final.checks.first { $0.id == "updated-rows" })
        XCTAssertThrowsError(try changed.result([changed.id: initialRows], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testCheckpointsUseSourceTransactionsAndExactAppliedPosition() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 5, "ddlApplied": 2, "rowsApplied": 1]
        let end = Boundary(file: "binlog.000001", position: 1000, gtids: "uuid:1-14")
        var after: [String: Any] = [
            "transactionsApplied": 14, "ddlApplied": 5, "rowsApplied": 22, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "1000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 21
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["rowsApplied"] = 22
        after["appliedPosition"] = ["file": end.file, "position": "999"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["appliedPosition"] = ["file": end.file, "position": "1000"]
        after["transactionsApplied"] = 15
        after["ddlApplied"] = 6
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: true))
    }

    func testCleanupTitleAndOnlyOneMoreChoiceCaseOptIn() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 6)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ch_after_insert,poc.ch_after_update"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM and SET: quoted values, comma labels, empty members and NULL")
        XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-choices" }?.test.name, fixture.displayName)
        for id in ["legacybinaryset", "enumzero", "choiceboundaries"] {
            XCTAssertNil(try XCTUnwrap(DMLCompatibilityCases.cases.first { $0.id == id }).workflow, id)
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "binarychoices", "identifiercase",
                "unicodeidentifiers", "choices",
                "widechoices",
            ])
    }
}
