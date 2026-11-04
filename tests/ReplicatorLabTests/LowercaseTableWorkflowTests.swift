import Foundation
import XCTest

@testable import ReplicatorLabCore

final class LowercaseTableWorkflowTests: XCTestCase {
    private let test = DDLCompatibilityCases.tableNameCase
    private let original = [
        "CREATE TABLE ddlcompat.`MiXÉ`(ID INT PRIMARY KEY,n INT DEFAULT 7)",
        "INSERT INTO DDLCOMPAT.`mixé`(id) VALUES(1)",
        "ALTER TABLE DDLCOMPAT.`MIXÉ` ADD extra INT DEFAULT 3",
        "UPDATE ddlcompat.`mixé` SET extra=9 WHERE id=1",
        "CREATE TABLE ddlcompat.`CoPy` LIKE DDLCOMPAT.`MIXÉ`",
        "INSERT INTO ddlcompat.`COPY` SELECT * FROM ddlcompat.`mixé`",
        "RENAME TABLE DDLCOMPAT.`COPY` TO ddlcompat.`Final`,ddlcompat.`MiXÉ` TO ddlcompat.`Old`",
        "UPDATE ddlcompat.`FINAL` SET n=8 WHERE id=1",
        "DROP TABLE ddlcompat.`OLD`",
        "DROP TABLE ddlcompat.`FINAL`",
    ]

    func testPhasesKeepRestartsTransactionsAndModeOneSelection() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [2, 5, 26])
        XCTAssertEqual(test.steps.count, 33)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [3, 8])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.assertionID == nil })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(LabVariant.lowercaseTables.lowerCaseTableNames, 1)
        let scenario = LabScenario(test: test.test, family: "ddl-compat")
        for profile in LabProfile.allCases {
            for variant in LabVariant.allCases {
                if variant == .lowercaseTables {
                    XCTAssertNil(scenario.reason(profile, variant: variant))
                } else {
                    XCTAssertNotNil(scenario.reason(profile, variant: variant))
                }
            }
        }
    }

    func testOriginalSQLKeepsMixedCaseAndAccentedBytes() {
        XCTAssertEqual(test.steps.prefix(10).map { Data($0.sql.utf8) }, original.map { Data($0.utf8) })
        XCTAssertEqual(Array("MiXÉ".utf8), [0x4d, 0x69, 0x58, 0xc3, 0x89])
        XCTAssertEqual(Array("mixé".utf8), [0x6d, 0x69, 0x78, 0xc3, 0xa9])
        XCTAssertEqual(
            test.steps[6].sql, "RENAME TABLE DDLCOMPAT.`COPY` TO ddlcompat.`Final`,ddlcompat.`MiXÉ` TO ddlcompat.`Old`")
        XCTAssertEqual(test.steps[8].sql, "DROP TABLE ddlcompat.`OLD`")
        XCTAssertEqual(test.steps[9].sql, "DROP TABLE ddlcompat.`FINAL`")
    }

    func testRetainedHistoriesKeepDatabaseQualifierCaseAndTableSpellings() {
        var offset = 10
        for (length, database) in [
            (2, "lc_after_insert"), (3, "lc_after_add"), (6, "lc_after_copy"), (8, "lc_after_rename"),
        ] {
            XCTAssertEqual(
                test.steps[offset].sql, "CREATE DATABASE " + database + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
            offset += 1
            // Only the ASCII database qualifier changes. Never fold table names.
            let expected = original.prefix(length).map {
                $0.replacingOccurrences(of: "ddlcompat.", with: database + ".")
                    .replacingOccurrences(of: "DDLCOMPAT.", with: database.uppercased() + ".")
            }
            let retained = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(retained.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertTrue(retained.allSatisfy { !$0.restartBefore })
            XCTAssertTrue(retained.contains { $0.sql.contains(database.uppercased() + ".") })
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
    }

    func testBothOriginalPredicatesKeepTheirRetainedStates() throws {
        let expected: [(String, String, String)] = [
            ("inserted-default-through-uppercase-name", "SELECT ID,n FROM lc_after_insert.`MIXÉ`", "1\t7"),
            ("updated-renamed-copy", "SELECT ID,n,extra FROM lc_after_rename.`final`", "1\t8\t9"),
        ]
        try checkObservations(expected)
    }

    func testFinalChecksKeepAddedDefaultsCopyRowsAndNameBytes() throws {
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 10)
        let expected: [(String, String, String)] = [
            ("materialized-added-default", "SELECT ID,n,extra FROM lc_after_add.`mixé` ORDER BY ID", "1\t7\t3"),
            ("updated-copy-source", "SELECT ID,n,extra FROM lc_after_copy.`MIXÉ` ORDER BY ID", "1\t7\t9"),
            ("copied-row", "SELECT ID,n,extra FROM lc_after_copy.`COPY` ORDER BY ID", "1\t7\t9"),
            ("unchanged-renamed-original", "SELECT ID,n,extra FROM lc_after_rename.`OLD` ORDER BY ID", "1\t7\t9"),
            (
                "lowercase-copy-name-bytes",
                "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='lc_after_copy' ORDER BY BINARY TABLE_NAME",
                "636F7079\n6D6978C3A9"
            ),
            (
                "lowercase-rename-name-bytes",
                "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='lc_after_rename' ORDER BY BINARY TABLE_NAME",
                "66696E616C\n6F6C64"
            ),
            (
                "stored-column-name-bytes",
                "SELECT HEX(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='lc_after_add' ORDER BY ORDINAL_POSITION",
                "4944\n6E\n6578747261"
            ),
            (
                "original-tables-dropped",
                "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat'", "0"
            ),
        ]
        try checkObservations(expected)
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testComparisonAndCleanupOwnOnlyRetainedDatabases() throws {
        let final = try XCTUnwrap(test.finalObservations)
        let retained = ["lc_after_insert", "lc_after_add", "lc_after_copy", "lc_after_rename"]
        XCTAssertEqual(final.databases, ["ddlcompat"] + retained)
        XCTAssertEqual(final.cleanup, retained.map { "DROP DATABASE " + $0 })
        XCTAssertFalse(final.cleanup.contains { $0.contains("ddlcompat") })
        XCTAssertEqual(test.steps.prefix(10).filter { $0.sql.hasPrefix("DROP TABLE ") }.count, 2)
    }

    private func checkObservations(_ expected: [(String, String, String)]) throws {
        let final = try XCTUnwrap(test.finalObservations)
        for (id, sql, value) in expected {
            let observation = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertEqual(Data(observation.check.sql.utf8), Data(sql.utf8))
            XCTAssertEqual(observation.check.expected, value)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try observation.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
            }
        }
    }
}
