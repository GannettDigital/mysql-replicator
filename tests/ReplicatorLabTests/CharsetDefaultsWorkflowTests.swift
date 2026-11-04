import Foundation
import XCTest

@testable import ReplicatorLabCore

final class CharsetDefaultsWorkflowTests: XCTestCase {
    private let test = DDLCompatibilityCases.charsetDefaults
    private let original = [
        "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin",
        "ALTER TABLE ddlcompat.t DEFAULT CHARSET=DEFAULT",
        "ALTER TABLE ddlcompat.t COLLATE latin1_bin, CHARACTER SET DEFAULT",
        "ALTER TABLE ddlcompat.t COLLATE DEFAULT",
        "ALTER TABLE ddlcompat.t CHARACTER SET latin1 COLLATE DEFAULT",
        "USE ddlcompat; ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET DEFAULT",
        "USE ddlcompat; SET SESSION collation_database=latin1_bin; ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET DEFAULT",
        "INSERT INTO ddlcompat.t VALUES(1,'café')",
        "UPDATE ddlcompat.t SET v='été' WHERE id=1",
        "DELETE FROM ddlcompat.t WHERE id=1",
    ]

    func testPhasesKeepRestartsTransactionsAndProfileRestrictions() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [5, 2, 1, 29, 3])
        XCTAssertEqual(test.steps.count, 40)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [6, 9])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.assertionID == nil })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertEqual(
            test.profileExclusions,
            [.forward: "MySQL 8.4 source rejects DEFAULT as a charset or collation name (error 1064)."])
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
    }

    func testOriginalSQLAndInterleavedHistoriesPreserveBytesAndOrder() throws {
        XCTAssertEqual(test.steps.prefix(10).map { Data($0.sql.utf8) }, original.map { Data($0.utf8) })
        for (length, table) in [
            (2, "cd_after_default"), (5, "cd_after_clauses"), (6, "cd_after_utf8"), (8, "cd_after_insert"),
            (9, "cd_after_update"),
        ] {
            let expected = original.prefix(length).map {
                $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table)
            }
            let retained = test.steps.dropFirst(10).filter { $0.sql.contains("ddlcompat." + table) }
            XCTAssertEqual(retained.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertTrue(retained.allSatisfy { !$0.restartBefore })
        }
        XCTAssertEqual(test.steps.filter { $0.sql.contains("CONVERT TO CHARACTER SET DEFAULT") }.count, 7)
    }

    func testFourOriginalPredicatesKeepTheCorrectStates() throws {
        let expected: [(String, String, String)] = [
            (
                "table-default-inherits-database",
                "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_default'",
                "utf8mb4_bin"
            ),
            (
                "later-default-clauses-inherit-database",
                "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_clauses'",
                "utf8mb4_bin"
            ),
            (
                "conversion-uses-database-default",
                "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_utf8' AND COLUMN_NAME='v'",
                "utf8mb4_bin"
            ),
            (
                "conversion-uses-session-override",
                "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='v'",
                "latin1_bin"
            ),
        ]
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

    func testFinalRowsMetadataAndOwnedCleanup() throws {
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 8)
        let expected: [(String, String, String)] = [
            ("inserted-row-bytes", "SELECT id,HEX(v) FROM ddlcompat.cd_after_insert ORDER BY id", "1\t636166E9"),
            ("updated-row-bytes", "SELECT id,HEX(v) FROM ddlcompat.cd_after_update ORDER BY id", "1\tE974E9"),
            ("deleted-original-row", "SELECT COUNT(*) FROM ddlcompat.t", "0"),
            (
                "final-table-collation",
                "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                "latin1_bin"
            ),
        ]
        for (id, sql, value) in expected {
            let observation = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertEqual(observation.check.sql, sql)
            XCTAssertEqual(observation.check.expected, value)
            _ = try observation.result([id: value], engine: "InnoDB", role: "target")
            XCTAssertThrowsError(try observation.result([id: "wrong"], engine: "InnoDB", role: "target"))
        }
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.cd_after_default,ddlcompat.cd_after_clauses,ddlcompat.cd_after_utf8,ddlcompat.cd_after_insert,ddlcompat.cd_after_update"
            ])
    }

    func testMainStatementsKeepTheirOriginalSessionContexts() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        for transactional in [false, true] {
            let scripts = phases.map { $0.writes(transactional: transactional).map(\.sql) }
            XCTAssertNoThrow(try validateSessionContexts(scripts))
        }
    }

    func testSessionGuardRejectsMergedBatchesAndMissingUse() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let scripts = phases.map { $0.writes(transactional: false).map(\.sql) }
        var mergedOriginal = scripts
        mergedOriginal[1] += mergedOriginal.remove(at: 2)
        XCTAssertThrowsError(try validateSessionContexts(mergedOriginal))
        var mergedRetained = scripts
        mergedRetained[3] += mergedRetained.remove(at: 4)
        XCTAssertThrowsError(try validateSessionContexts(mergedRetained))
        var selectedTooSoon = scripts
        selectedTooSoon[0][0] = "USE ddlcompat; " + selectedTooSoon[0][0]
        XCTAssertThrowsError(try validateSessionContexts(selectedTooSoon))
        var missingUse = scripts
        let lastUTF8Conversion = try XCTUnwrap(
            missingUse[3].lastIndex {
                $0.contains("ALTER TABLE ddlcompat.cd_after_update CONVERT")
                    && !$0.contains("collation_database=latin1_bin")
            })
        missingUse[3][lastUTF8Conversion] = missingUse[3][lastUTF8Conversion].replacingOccurrences(
            of: "USE ddlcompat; ", with: "")
        XCTAssertThrowsError(try validateSessionContexts(missingUse))
    }

    // This is a model of this fixture's session commands, not a SQL parser or
    // proof of MySQL behavior. The focused integration test checks native results.
    private enum SessionMismatch: Error { case leakedContext }

    private func validateSessionContexts(_ phases: [[String]]) throws {
        for phase in phases {
            var selected = false
            var collation = "global-baseline"
            for write in phase {
                for part in write.split(separator: ";") {
                    let sql = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sql == "USE ddlcompat" {
                        selected = true
                        collation = "utf8mb4_bin"
                    } else if sql == "SET SESSION collation_database=latin1_bin" {
                        collation = "latin1_bin"
                    } else if sql.hasPrefix("SET ") {
                        continue
                    } else if sql.contains("CONVERT TO CHARACTER SET DEFAULT") {
                        let expected =
                            write.contains("SET SESSION collation_database=latin1_bin") ? "latin1_bin" : "utf8mb4_bin"
                        guard selected && collation == expected else { throw SessionMismatch.leakedContext }
                    } else {
                        guard !selected && collation == "global-baseline" else { throw SessionMismatch.leakedContext }
                    }
                }
            }
        }
    }
}
