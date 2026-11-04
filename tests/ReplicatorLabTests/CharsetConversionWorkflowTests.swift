import Foundation
import XCTest

@testable import ReplicatorLabCore

final class CharsetConversionWorkflowTests: XCTestCase {
    private let test = DDLCompatibilityCases.charsetConversion

    func testPhasesKeepOriginalRestartsAndTransactions() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [3, 3, 2, 16])
        XCTAssertEqual(test.steps.count, 24)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [4, 7, 9])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.assertionID == nil })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
    }

    func testOriginalSQLAndRetainedHistoriesPreserveBytes() throws {
        let original = [
            "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20) NOT NULL DEFAULT 'café',e ENUM('one','a') DEFAULT 'a',s SET('one','a') DEFAULT 'a',tx TEXT,small_tx TINYTEXT,b VARBINARY(8),g VARCHAR(20) AS (v) STORED,KEY by_v(v(8))) DEFAULT CHARSET=latin1 COLLATE=latin1_bin",
            "INSERT INTO ddlcompat.t(id,e,s,tx,small_tx,b) VALUES(1,'one','one,a','été','café',X'00FF')",
            "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            "INSERT INTO ddlcompat.t(id) VALUES(2)",
            "ALTER TABLE ddlcompat.t ADD added VARCHAR(10) CHARACTER SET latin1 DEFAULT 'new', CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            "UPDATE ddlcompat.t SET v='été',tx='café',added='é' WHERE id=1",
            "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET binary",
            "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
            "UPDATE ddlcompat.t SET v=X'00FF',tx=X'FE',b=X'FF00' WHERE id=1",
            "DELETE FROM ddlcompat.t WHERE id=2",
        ]
        XCTAssertEqual(test.steps.prefix(10).map { Data($0.sql.utf8) }, original.map { Data($0.utf8) })
        var offset = 10
        for (length, table) in [(3, "cv_after_utf8"), (4, "cv_after_defaults"), (7, "cv_after_binary")] {
            let expected = original.prefix(length).map {
                $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table)
            }
            let retained = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(retained.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertTrue(retained.allSatisfy { !$0.restartBefore })
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertEqual(test.steps.filter { $0.sql.contains("CONVERT TO CHARACTER SET") }.count, 9)
    }

    func testOriginalPredicatesRemainOnTheirRetainedStates() throws {
        let expected: [(String, String, String)] = [
            (
                "utf8-widened-types",
                "SELECT COLUMN_NAME,DATA_TYPE,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cv_after_utf8' AND COLUMN_NAME IN ('tx','small_tx','b') ORDER BY ORDINAL_POSITION",
                "tx\tmediumtext\tutf8mb4_bin\nsmall_tx\ttext\tutf8mb4_bin\nb\tvarbinary\tNULL"
            ),
            (
                "utf8-row-bytes", "SELECT HEX(v),HEX(e),HEX(s),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.cv_after_utf8",
                "636166C3A9\t6F6E65\t6F6E652C61\tC3A974C3A9\t00FF\t636166C3A9"
            ),
            (
                "utf8-inserted-defaults", "SELECT HEX(v),e,s FROM ddlcompat.cv_after_defaults WHERE id=2",
                "636166C3A9\ta\ta"
            ),
            (
                "binary-column-types",
                "SELECT COLUMN_NAME,DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cv_after_binary' AND COLUMN_NAME IN ('v','tx','small_tx') ORDER BY ORDINAL_POSITION",
                "v\tvarbinary\ntx\tmediumblob\nsmall_tx\tblob"
            ),
            (
                "binary-row-bytes", "SELECT HEX(v),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.cv_after_binary WHERE id=1",
                "C3A974C3A9\t636166C3A9\t00FF\tC3A974C3A9"
            ),
            (
                "final-binary-row-bytes", "SELECT HEX(v),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.t WHERE id=1",
                "00FF\tFE\tFF00\t00FF"
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

    func testFinalBinaryTypesDeleteAndCleanupRemainExplicit() throws {
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 8)
        let types = try XCTUnwrap(final.checks.first { $0.id == "final-binary-column-types" })
        XCTAssertEqual(
            types.check.sql,
            "SELECT COLUMN_NAME,DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME IN ('v','tx','small_tx') ORDER BY ORDINAL_POSITION"
        )
        XCTAssertEqual(types.check.expected, "v\tvarbinary\ntx\tmediumblob\nsmall_tx\tblob")
        let deleted = try XCTUnwrap(final.checks.first { $0.id == "deleted-second-row" })
        XCTAssertEqual(deleted.check.sql, "SELECT COUNT(*) FROM ddlcompat.t WHERE id=2")
        XCTAssertEqual(deleted.check.expected, "0")
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(
            final.cleanup, ["DROP TABLE ddlcompat.cv_after_utf8,ddlcompat.cv_after_defaults,ddlcompat.cv_after_binary"])
    }
}
