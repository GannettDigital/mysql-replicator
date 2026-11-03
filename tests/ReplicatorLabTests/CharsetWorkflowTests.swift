import XCTest

@testable import ReplicatorLabCore

final class CharsetWorkflowTests: XCTestCase {
    private var cases: [DDLCompatibilityCases.Case] {
        [DDLCompatibilityCases.tableCharset, DDLCompatibilityCases.compoundCharset]
    }

    func testPhasesKeepRestartPositionsAndTransactionCounts() throws {
        for (index, test) in cases.enumerated() {
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
            let final = try XCTUnwrap(test.finalObservations)
            try final.validate(phases)
            XCTAssertEqual(phases.map { $0.steps.count }, index == 0 ? [3, 4, 10] : [3, 2, 5])
            XCTAssertEqual(test.steps.count, index == 0 ? 17 : 10)
            XCTAssertEqual(
                test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 },
                index == 0 ? [4, 8] : [4, 6])
            XCTAssertTrue(
                test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil }
            )
            XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
            XCTAssertTrue(test.profileExclusions.isEmpty)
            XCTAssertFalse(test.nativeInnoDB)
            XCTAssertEqual(final.databases, ["ddlcompat"])
            XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        }
    }

    func testHistoriesKeepAlterOrderLiteralBytesAndOwnedCleanup() throws {
        let table = cases[0]
        var offset = 9
        for (length, name) in [(3, "tc_after_default"), (5, "tc_after_update")] {
            let expected = table.steps.prefix(length).map {
                $0.sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + name)
            }
            let retained = Array(table.steps[offset..<offset + length])
            XCTAssertEqual(retained.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertTrue(retained.allSatisfy { !$0.restartBefore })
            offset += length
        }
        XCTAssertEqual(offset, table.steps.count)
        XCTAssertEqual(
            table.steps[2].sql,
            "ALTER TABLE ddlcompat.t ADD next_v VARCHAR(20) DEFAULT 'new', DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin"
        )
        XCTAssertEqual(
            table.steps[3].sql,
            "ALTER TABLE ddlcompat.t DEFAULT CHARSET=latin1 COLLATE=latin1_bin, ADD last_v VARCHAR(20) DEFAULT 'fin'")
        XCTAssertEqual(table.steps[8].sql, "DELETE FROM ddlcompat.t WHERE id=1")
        XCTAssertTrue(table.steps[0].sql.contains("DEFAULT 'café'"))
        XCTAssertTrue(table.steps[4].sql.contains("v='été',next_v='été',last_v='été'"))
        XCTAssertEqual(
            table.finalObservations?.cleanup, ["DROP TABLE ddlcompat.tc_after_default,ddlcompat.tc_after_update"])
        let compound = cases[1]
        let copied = compound.steps.prefix(3).map {
            $0.sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat.cc_after_convert")
        }
        XCTAssertEqual(compound.steps.suffix(3).map { Data($0.sql.utf8) }, copied.map { Data($0.utf8) })
        XCTAssertEqual(
            compound.steps[2].sql,
            "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT COLLATE utf8mb4_general_ci, ADD n VARCHAR(20) DEFAULT 'new'"
        )
        XCTAssertEqual(compound.steps[6].sql, "DELETE FROM ddlcompat.t WHERE id=2")
        XCTAssertEqual(compound.finalObservations?.cleanup, ["DROP TABLE ddlcompat.cc_after_convert"])
    }

    func testSevenOriginalPredicatesRemainOnTheCorrectStates() throws {
        let expected: [[(String, String)]] = [
            [
                (
                    "SELECT COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='tc_after_default' AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION",
                    "v\tlatin1_bin\nnext_v\tutf8mb4_bin"
                ),
                ("SELECT HEX(v),HEX(next_v) FROM ddlcompat.tc_after_default", "636166E9\t6E6577"),
                ("SELECT HEX(v),HEX(next_v),HEX(last_v) FROM ddlcompat.tc_after_update", "E974E9\tC3A974C3A9\tE974E9"),
                (
                    "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy'",
                    "latin1_swedish_ci"
                ),
            ],
            [
                (
                    "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                    "utf8mb4_general_ci"
                ),
                (
                    "SELECT COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cc_after_convert' AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION",
                    "v\tutf8mb4_bin\nn\tutf8mb4_bin"
                ),
                (
                    "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='follows'",
                    "utf8mb4_general_ci"
                ),
            ],
        ]
        for (test, predicates) in zip(cases, expected) {
            let final = try XCTUnwrap(test.finalObservations)
            XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
            XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
            for (sql, value) in predicates {
                let observation = try XCTUnwrap(final.checks.first { $0.check.sql == sql })
                XCTAssertEqual(observation.check.expected, value)
                for engine in ["InnoDB", "MyISAM"] {
                    _ = try observation.result([observation.id: value], engine: engine, role: "target")
                    XCTAssertThrowsError(
                        try observation.result([observation.id: "wrong"], engine: engine, role: "target"))
                }
            }
        }
    }

    func testFinalMetadataAndRowsDistinguishDefaultsFromConversion() throws {
        let table = try XCTUnwrap(cases[0].finalObservations)
        XCTAssertEqual(table.checks.count, 8)
        XCTAssertEqual(table.checks.first { $0.id == "final-table-collation" }?.check.expected, "latin1_swedish_ci")
        XCTAssertEqual(
            table.checks.first { $0.id == "final-column-collations" }?.check.expected,
            "v\tlatin1_bin\nnext_v\tutf8mb4_bin\nlast_v\tlatin1_bin")
        XCTAssertEqual(table.checks.first { $0.id == "deleted-original-row" }?.check.expected, "0")
        let copy = try XCTUnwrap(table.checks.first { $0.id == "like-default-row" })
        XCTAssertEqual(copy.check.sql, "SELECT id,HEX(v),HEX(next_v),HEX(last_v) FROM ddlcompat.copy ORDER BY id")
        XCTAssertEqual(copy.check.expected, "2\t636166E9\t6E6577\t66696E")
        let compound = try XCTUnwrap(cases[1].finalObservations)
        XCTAssertEqual(compound.checks.count, 4)
        let row = try XCTUnwrap(compound.checks.first { $0.id == "final-row-bytes" })
        XCTAssertEqual(row.check.sql, "SELECT id,HEX(v),HEX(n),HEX(follows) FROM ddlcompat.t ORDER BY id")
        XCTAssertEqual(row.check.expected, "1\tC3A974C3A9\t636166C3A9\t6C61746572")
    }
}
