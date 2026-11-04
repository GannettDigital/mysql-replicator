import Foundation
import XCTest

@testable import ReplicatorLabCore

final class UnicodeTableWorkflowTests: XCTestCase {
    private let test = DDLCompatibilityCases.unicodeNames
    private let original = [
        "CREATE TABLE ddlcompat.`é`(id INT PRIMARY KEY,值 INT)",
        "CREATE TABLE ddlcompat.`e\u{0301}`(id INT PRIMARY KEY,值 INT)",
        "INSERT INTO ddlcompat.`é` VALUES(1,10)",
        "INSERT INTO ddlcompat.`e\u{0301}` VALUES(1,20)",
        "UPDATE ddlcompat.`é` SET 值=11 WHERE id=1",
        "RENAME TABLE ddlcompat.`é` TO ddlcompat.中",
        "INSERT INTO ddlcompat.中 VALUES(2,12)",
        "DROP TABLE ddlcompat.`e\u{0301}`",
        "CREATE TABLE ddlcompat.`select` LIKE ddlcompat.中",
        "INSERT INTO ddlcompat.`select` VALUES(1,30)",
        "DROP TABLE ddlcompat.中",
        "DROP TABLE ddlcompat.`select`",
        "CREATE TABLE ddlcompat.`😀`(id INT PRIMARY KEY,`😀` INT)",
        "INSERT INTO ddlcompat.`😀` VALUES(1,40)",
        "DROP TABLE ddlcompat.😀",
    ]

    func testOnePhaseKeepsTransactionsAndModeZeroSelection() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [48])
        XCTAssertEqual(phases.map(\.id), ["unicode-table-names-and-retained-results"])
        XCTAssertTrue(
            test.steps.allSatisfy {
                !$0.restartBefore && $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.assertionID == nil
            })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        let scenario = LabScenario(test: test.test, family: "ddl-compat")
        for profile in LabProfile.allCases {
            XCTAssertNil(scenario.reason(profile, variant: .standard))
            XCTAssertNotNil(scenario.reason(profile, variant: .lowercaseTables))
        }
    }

    func testOriginalSourceAndScalarBytesStayExact() {
        XCTAssertEqual(test.steps.prefix(15).map { Data($0.sql.utf8) }, original.map { Data($0.utf8) })
        XCTAssertEqual(Array("é".utf8), [0xc3, 0xa9])
        XCTAssertEqual(Array("e\u{0301}".utf8), [0x65, 0xcc, 0x81])
        XCTAssertNotEqual(Data("é".utf8), Data("e\u{0301}".utf8))
        XCTAssertEqual(Array("中".utf8), [0xe4, 0xb8, 0xad])
        XCTAssertEqual(Array("😀".utf8), [0xf0, 0x9f, 0x98, 0x80])
        XCTAssertEqual(test.steps[8].sql, "CREATE TABLE ddlcompat.`select` LIKE ddlcompat.中")
        XCTAssertEqual(test.steps[12].sql, "CREATE TABLE ddlcompat.`😀`(id INT PRIMARY KEY,`😀` INT)")
        XCTAssertEqual(test.steps[14].sql, "DROP TABLE ddlcompat.😀")
    }

    func testHistoriesChangeOnlyDatabaseQualifiers() throws {
        let histories: [(String, [Int])] = [
            ("un_after_insert", Array(0..<4)), ("un_after_update", Array(0..<5)),
            ("un_after_rename", Array(0..<7)), ("un_after_like", Array(0..<10)),
            ("un_supplementary", [12, 13]),
        ]
        var offset = 15
        for (database, indices) in histories {
            XCTAssertEqual(
                test.steps[offset].sql, "CREATE DATABASE " + database + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
            offset += 1
            let expected = indices.map { original[$0].replacingOccurrences(of: "ddlcompat.", with: database + ".") }
            let actual = test.steps[offset..<offset + indices.count].map { Data($0.sql.utf8) }
            XCTAssertEqual(actual, expected.map { Data($0.utf8) })
            offset += indices.count
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertFalse(test.steps.contains { $0.sql.contains("USE ") || $0.sql.contains("SET NAMES") })
    }

    func testFourOriginalPredicatesKeepTheirEarlierResults() throws {
        let expected: [(String, String, String)] = [
            ("updated-precomposed-row", "SELECT 值 FROM un_after_update.`é`", "11"),
            ("untouched-decomposed-row", "SELECT 值 FROM un_after_update.`e\u{0301}`", "20"),
            ("renamed-table-rows", "SELECT 值 FROM un_after_rename.中 ORDER BY id", "11\n12"),
            ("native-supplementary-name-row", "SELECT `?` FROM un_supplementary.`?`", "40"),
        ]
        try checkObservations(expected)
    }

    func testFinalQueriesKeepRowsNameBytesAndOriginalDrops() throws {
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 12)
        let expected: [(String, String, String)] = [
            ("inserted-precomposed-row", "SELECT id,值 FROM un_after_insert.`é` ORDER BY id", "1\t10"),
            ("inserted-decomposed-row", "SELECT id,值 FROM un_after_insert.`e\u{0301}` ORDER BY id", "1\t20"),
            (
                "separate-name-bytes",
                "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_update' ORDER BY BINARY TABLE_NAME",
                "65CC81\nC3A9"
            ),
            (
                "renamed-name-bytes",
                "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_rename' ORDER BY BINARY TABLE_NAME",
                "65CC81\nE4B8AD"
            ),
            ("quoted-like-table-row", "SELECT id,值 FROM un_after_like.`select` ORDER BY id", "1\t30"),
            (
                "like-and-drop-name-bytes",
                "SELECT HEX(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='un_after_like' ORDER BY BINARY TABLE_NAME",
                "73656C656374\nE4B8AD"
            ),
            (
                "native-stored-name-bytes",
                "SELECT HEX(TABLE_NAME),HEX(COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='un_supplementary' AND COLUMN_NAME<>'id' ORDER BY BINARY TABLE_NAME,ORDINAL_POSITION",
                "3F\t3F"
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

    func testComparisonAndCleanupOwnOnlyTheRetainedDatabases() throws {
        let final = try XCTUnwrap(test.finalObservations)
        let retained = ["un_after_insert", "un_after_update", "un_after_rename", "un_after_like", "un_supplementary"]
        XCTAssertEqual(final.databases, ["ddlcompat"] + retained)
        XCTAssertEqual(final.cleanup, retained.map { "DROP DATABASE " + $0 })
        XCTAssertEqual(final.cleanup.count, 5)
        XCTAssertFalse(final.cleanup.contains { $0.contains("ddlcompat") })
        XCTAssertEqual(test.steps.prefix(15).filter { $0.sql.hasPrefix("DROP TABLE ") }.count, 4)
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
