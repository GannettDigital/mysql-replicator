import Foundation
import XCTest

@testable import ReplicatorLabCore

final class UnicodeDMLWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.unicodeIdentifiers }
    private let long = String(repeating: "中", count: 64)
    private var originalSQL: [String] {
        [
            "INSERT INTO poc.matrix_unicodeidentifiers(id,值,`a``b`,`\(long)`) VALUES(1,30,40,50),(2,NULL,NULL,NULL)",
            "UPDATE poc.matrix_unicodeidentifiers SET `É`=11,`e\u{0301}`=21,值=31 WHERE id=1; ALTER TABLE poc.matrix_unicodeidentifiers ADD 列 INT DEFAULT 7 AFTER 值",
            "ALTER TABLE poc.matrix_unicodeidentifiers CHANGE `É` 改名 BIGINT DEFAULT 15; ALTER TABLE poc.matrix_unicodeidentifiers RENAME INDEX `É` TO 键; UPDATE poc.matrix_unicodeidentifiers SET 改名=DEFAULT,`a``b`=41 WHERE id=2",
            "ALTER TABLE poc.matrix_unicodeidentifiers DROP INDEX 键, DROP COLUMN 列; DELETE FROM poc.matrix_unicodeidentifiers WHERE id=1",
        ]
    }
    private var originalChecks: [String] {
        [
            "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=10 AND `e\u{0301}`=20 AND 值=30 AND `a``b`=40 AND `\(long)`=50",
            "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=11 AND `e\u{0301}`=21 AND 值=31 AND 列=7",
            "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=2 AND 改名=15 AND `e\u{0301}`=20 AND `a``b`=41",
            "SELECT COUNT(*)=1 AND SUM(改名)=15 FROM poc.matrix_unicodeidentifiers",
        ]
    }

    func testOriginalBytesAndMetadataInputsRemain() throws {
        let definition =
            "id INT PRIMARY KEY,`é` INT DEFAULT 10,`e\u{0301}` INT DEFAULT 20,值 INT,`a``b` INT,`\(long)` INT,KEY `é`(`é`,id),KEY `e\u{0301}`(`e\u{0301}`,id)"
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map { Data($0.check.utf8) }, originalChecks.map { Data($0.utf8) })
        XCTAssertNotEqual(Data("é".utf8), Data("e\u{0301}".utf8))
        XCTAssertEqual(long.count, 64)
        XCTAssertEqual(long.utf8.count, 192)
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
            let metadata = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(metadata.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(Data(metadata.phases[0].sql.utf8), Data(originalSQL[0].utf8))
            XCTAssertEqual(Data(metadata.phases[0].check.utf8), Data(originalChecks[0].utf8))
        }
    }

    func testBatchesPreserveScriptsSessionsAndTransactionCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.prepare.writes.count, 4)
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.transactions, [1, 2, 3, 2, 1, 1, 2, 1, 2, 3])
        XCTAssertEqual(plan.body.transactionCount, 18)
        XCTAssertEqual(plan.expectedDDL, 12)
        XCTAssertEqual(plan.expectedRows, 14)
        let tables = ["matrix_unicodeidentifiers", "ui_after_insert", "ui_after_add", "ui_after_rename"]
        for (write, table) in zip(plan.prepare.writes, tables) {
            XCTAssertEqual(
                Data(write.sql.utf8),
                Data(
                    ("CREATE TABLE poc." + table + "(" + fixture.definition
                        + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin").utf8))
        }
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (length, table) in [(1, "ui_after_insert"), (2, "ui_after_add"), (3, "ui_after_rename")] {
            expected += originalSQL.prefix(length).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_unicodeidentifiers", with: "poc." + table)
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

    func testFourOriginalPredicatesKeepExactBytes() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["ui_after_insert", "ui_after_add", "ui_after_rename", "matrix_unicodeidentifiers"]
        for (index, sql) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                Data(check.check.sql.utf8),
                Data(sql.replacingOccurrences(of: "poc.matrix_unicodeidentifiers", with: "poc." + tables[index]).utf8))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testFullRowsRetainDefaultsNullsAndDeletedValues() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let expected = [
            "initial-rows": "1\t10\t20\t30\t40\t50\n2\t10\t20\tNULL\tNULL\tNULL",
            "added-column-rows": "1\t11\t21\t31\t7\t40\t50\n2\t10\t20\tNULL\t7\tNULL\tNULL",
            "renamed-rows": "1\t11\t21\t31\t7\t40\t50\n2\t15\t20\tNULL\t7\t41\tNULL",
            "surviving-row": "2\t15\t20\tNULL\t41\tNULL",
        ]
        for (id, value) in expected {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.expected, value)
            XCTAssertTrue(check.check.sql.contains("`a``b`"))
            XCTAssertTrue(check.check.sql.contains("`" + long + "`"))
            XCTAssertTrue(check.check.sql.hasSuffix("ORDER BY id"))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([id: value + "\n3"], engine: engine, role: "target"))
            }
        }
        XCTAssertEqual(plan.final.checks.count, 14)
        XCTAssertTrue(plan.final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testNameBytesLengthAndIndexKeyOrderHaveFixedExpectations() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let hexLong = String(repeating: "E4B8AD", count: 64) + "\t64"
        let expected = [
            "initial-column-name-bytes": "6964\t2\nC3A9\t1\n65CC81\t2\nE580BC\t1\n616062\t3\n" + hexLong,
            "renamed-column-name-bytes": "6964\t2\nE694B9E5908D\t2\n65CC81\t2\nE580BC\t1\nE58897\t1\n616062\t3\n"
                + hexLong,
            "final-column-name-bytes": "6964\t2\nE694B9E5908D\t2\n65CC81\t2\nE580BC\t1\n616062\t3\n" + hexLong,
            "initial-index-key-parts": "65CC81\t1\t65CC81\n65CC81\t2\t6964\nC3A9\t1\tC3A9\nC3A9\t2\t6964",
            "renamed-index-key-parts": "65CC81\t1\t65CC81\n65CC81\t2\t6964\nE994AE\t1\tE694B9E5908D\nE994AE\t2\t6964",
            "surviving-index-key-parts": "65CC81\t1\t65CC81\n65CC81\t2\t6964",
        ]
        for (id, value) in expected {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            XCTAssertTrue(check.check.sql.contains("HEX(COLUMN_NAME)"))
            _ = try check.result([id: value], engine: "MyISAM", role: "target")
            let normalized = value.replacingOccurrences(of: "65CC81", with: "C3A9")
            XCTAssertThrowsError(try check.result([id: normalized], engine: "MyISAM", role: "target"))
            if id.hasSuffix("key-parts") {
                XCTAssertTrue(check.check.sql.hasSuffix("ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX"))
                XCTAssertThrowsError(
                    try check.result(
                        [id: value.split(separator: "\n").reversed().joined(separator: "\n")], engine: "MyISAM",
                        role: "target"))
            } else {
                XCTAssertTrue(check.check.sql.contains("CHAR_LENGTH(COLUMN_NAME)"))
                XCTAssertTrue(check.check.sql.hasSuffix("ORDER BY ORDINAL_POSITION"))
                XCTAssertThrowsError(
                    try check.result(
                        [id: value.replacingOccurrences(of: "\t64", with: "\t63")], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testCleanupKeepsOriginalAndTitleMatchesInventory() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ui_after_insert,poc.ui_after_add,poc.ui_after_rename"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(fixture.displayName, "Schema object names: Unicode columns, indexes and quoted identifiers")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-unicodeidentifiers" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            ["collations", "nativeencodings", "identifiercase", "unicodeidentifiers", "choices", "widechoices"])
    }
}
