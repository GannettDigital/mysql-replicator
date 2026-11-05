import Foundation
import XCTest

@testable import ReplicatorLabCore

final class DMLIdentifierWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.identifierCase }
    private let originalSQL = [
        "INSERT INTO poc.matrix_identifiercase(ID) VALUES(1),(2)",
        "ALTER TABLE poc.matrix_identifiercase ALTER COLUMN VALUE SET DEFAULT 9, ADD extra INT DEFAULT 3 AFTER VALUE; UPDATE poc.matrix_identifiercase SET VALUE=DEFAULT,EXTRA=4 WHERE ID=1",
        "ALTER TABLE poc.matrix_identifiercase CHANGE VALUE renamed BIGINT DEFAULT 5; ALTER TABLE poc.matrix_identifiercase RENAME INDEX valuekey TO RenamedKey; UPDATE poc.matrix_identifiercase SET RENAMED=DEFAULT WHERE ID=2",
        "ALTER TABLE poc.matrix_identifiercase DROP INDEX renamedkey, DROP COLUMN EXTRA; DELETE FROM poc.matrix_identifiercase WHERE ID=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=2 AND SUM(VALUE)=14 FROM poc.matrix_identifiercase",
        "SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=1 AND Value=9 AND extra=4",
        "SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=2 AND renamed=5",
        "SELECT COUNT(*)=1 AND SUM(RENAMED)=5 FROM poc.matrix_identifiercase",
    ]

    func testOriginalDefinitionAndPhasesRemainMetadataInputs() throws {
        XCTAssertEqual(fixture.definition, "id INT,Value INT DEFAULT 7,PRIMARY KEY(ID),KEY ValueKey(VALUE)")
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertNil(fixture.replicatedReplacement)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings", "enumzero", "choices",
                "widechoices",
            ])
        for profile in LabProfile.allCases {
            let metadata = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(metadata.definition, fixture.definition)
            XCTAssertEqual(metadata.phases[0].sql, originalSQL[0])
            XCTAssertEqual(metadata.phases[0].check, originalChecks[0])
        }
    }

    func testOriginalAndRetainedScriptsKeepOrderAndExactBytes() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.prepare.writes[0].sql,
            "CREATE TABLE poc.matrix_identifiercase(id INT,Value INT DEFAULT 7,PRIMARY KEY(ID),KEY ValueKey(VALUE)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
        )
        XCTAssertEqual(
            plan.body.writes.prefix(4).map { Data($0.sql.utf8) }, originalSQL.map { Data(("USE poc; " + $0).utf8) })
        var offset = 4
        for (length, table) in [(1, "ic_after_insert"), (2, "ic_after_alter"), (3, "ic_after_rename")] {
            let expected = originalSQL.prefix(length).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_identifiercase", with: "poc." + table)
            }
            XCTAssertEqual(
                plan.body.writes[offset..<offset + length].map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            offset += length
        }
        XCTAssertEqual(offset, plan.body.writes.count)
        for write in plan.prepare.writes {
            XCTAssertTrue(
                write.sql.contains("(" + fixture.definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"))
        }
    }

    func testAllFourPredicatesKeepTheirOriginalSQLAndExpectedValue() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["poc.ic_after_insert", "poc.ic_after_alter", "poc.ic_after_rename", "poc.matrix_identifiercase"]
        for (index, expected) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                Data(check.check.sql.utf8),
                Data(expected.replacingOccurrences(of: "poc.matrix_identifiercase", with: tables[index]).utf8))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testFullRowsAndIndexResultsRejectChangedValues() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let expected = [
            "initial-rows": "1\t7\n2\t7", "altered-rows": "1\t9\t4\n2\t7\t3", "renamed-rows": "1\t9\t4\n2\t5\t3",
            "surviving-row": "2\t5", "retained-index-name": "RenamedKey", "dropped-secondary-index": "0",
        ]
        XCTAssertEqual(plan.final.checks.count, 10)
        for (id, value) in expected {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.expected, value)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([id: "wrong"], engine: engine, role: "target"))
            }
        }
        XCTAssertTrue(plan.final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testCleanupKeepsOriginalTableAndTitleIsShared() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ic_after_insert,poc.ic_after_alter,poc.ic_after_rename"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertFalse(plan.cleanup.writes.contains { $0.sql.contains("matrix_identifiercase") })
        XCTAssertEqual(fixture.displayName, "Identifier case sensitivity: column, PRIMARY KEY and index references")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-identifiercase" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.unicodeIdentifiers.displayName,
            "Schema object names: Unicode columns, indexes and quoted identifiers")
    }
}
