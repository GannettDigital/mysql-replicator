import XCTest

@testable import ReplicatorLabCore

final class ColumnDefinitionWorkflowTests: XCTestCase {
    private func verifyPrefixes(
        _ test: DDLCompatibilityCases.Case, originalCount: Int, retained: [(String, Int)]
    ) throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        try XCTUnwrap(test.finalObservations).validate(phases)
        let original = Array(test.steps.prefix(originalCount))
        var start = originalCount
        for (table, count) in retained {
            for (index, step) in test.steps[start..<start + count].enumerated() {
                XCTAssertEqual(
                    step.sql, original[index].sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table))
                XCTAssertEqual(step.sqlTransactional, step.sql)
                XCTAssertFalse(step.restartBefore)
            }
            start += count
        }
        XCTAssertEqual(test.steps.count, start)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertEqual(test.finalObservations?.databases, ["ddlcompat"])
        XCTAssertEqual(
            test.finalObservations?.cleanup,
            ["DROP TABLE " + retained.map { "ddlcompat." + $0.0 }.joined(separator: ",")])
    }

    func testDefinitionsRetainValuesBeforeUpdateAndDelete() throws {
        let test = DDLCompatibilityCases.columnDefinitions
        try verifyPrefixes(
            test, originalCount: 5, retained: [("cd_initial", 2), ("cd_observed", 3), ("cd_updated", 4)])
        XCTAssertEqual(try DDLExecutionPhase.plan(test.steps)?.count, 1)
        XCTAssertFalse(test.steps.contains(where: \.restartBefore))
        XCTAssertEqual(test.steps[4].sql, "DELETE FROM ddlcompat.t WHERE id=1")
        let checks = Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(test.finalObservations).checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(checks["initial-defaults-and-bytes"], "1\t-7\t1.250\t00FF\ta\tx,y\thello")
        XCTAssertEqual(checks["timestamp-add-and-normalized-defaults"], "2023-11-14 22:13:20.123456\t7\t6869000000")
        XCTAssertEqual(checks["updated-row"], "1\t42.125\tchanged\tnext")
        XCTAssertEqual(checks["automatic-datetime-updated"], "1")
        XCTAssertEqual(checks["original-row-deleted"], "0")
    }

    func testTimestampResetPrecedesEachOperationAndKeepsWarnings() throws {
        let test = DDLCompatibilityCases.columnDefinitions
        let phase = try XCTUnwrap(DDLExecutionPhase.plan(test.steps)?.first)
        for transactional in [false, true] {
            let writes = phase.writes(transactional: transactional)
            for (step, write) in zip(test.steps, writes) {
                XCTAssertEqual(
                    write.sql,
                    "SET SESSION auto_increment_increment=@@GLOBAL.auto_increment_increment,auto_increment_offset=@@GLOBAL.auto_increment_offset; SET SESSION timestamp=DEFAULT; "
                        + step.sql)
            }
            XCTAssertTrue(writes[2].sql.contains("timestamp=DEFAULT; SET SESSION timestamp=1700000000.123456; ALTER"))
            XCTAssertFalse(writes[3].sql.contains("timestamp=1700000000"))
            let queries = try LabSQLPhase.queries(writes, session: "", status: "SHOW BINARY LOG STATUS")
            let warning = try XCTUnwrap(queries.first { $0.name == writes[2].id + "/warnings" })
            XCTAssertTrue(warning.sql.hasSuffix(test.steps[2].sql + "; SHOW WARNINGS"))
        }
    }

    func testCompoundAlterRetainsDefaultsIndexesAndCompositeKey() throws {
        let test = DDLCompatibilityCases.compoundColumnAlter
        try verifyPrefixes(test, originalCount: 8, retained: [("ca_initial", 2), ("ca_added", 4), ("ca_moved", 6)])
        XCTAssertEqual(try DDLExecutionPhase.plan(test.steps)?.count, 1)
        XCTAssertFalse(test.steps.contains(where: \.restartBefore))
        XCTAssertTrue(test.steps[2].sql.hasSuffix("ALGORITHM=COPY, LOCK=EXCLUSIVE"))
        XCTAssertEqual(
            test.steps[6].sql, "ALTER TABLE ddlcompat.t DROP COLUMN caption, ALTER COLUMN amount DROP DEFAULT")
        let checks = Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(test.finalObservations).checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(checks["compound-alter-and-default-insert"], "1\tseed\t-2.50\n2\trenamed\t-2.50")
        XCTAssertEqual(checks["compound-alter-id-default"], "10")
        XCTAssertEqual(checks["composite-key-order"], "report_date\nid")
        XCTAssertEqual(checks["drop-column-and-delete"], "2026-01-01\t1\t-2.50")
        XCTAssertEqual(checks["amount-default-removed"], "1")
        XCTAssertEqual(checks["dependent-index-removed"], "0")
    }
    func testConversionsRetainIntermediateTypesAndFractionalRow() throws {
        let test = DDLCompatibilityCases.alterConversions
        try verifyPrefixes(
            test, originalCount: 14,
            retained: [
                ("cv_initial", 2), ("cv_varchar", 3), ("cv_decimal", 6),
                ("cv_double", 8), ("cv_integer", 9), ("cv_bit", 11),
            ])
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        XCTAssertEqual(phases.count, 4)
        XCTAssertEqual(
            test.steps.filter(\.restartBefore).map(\.sql),
            [
                "UPDATE ddlcompat.t SET n='56' WHERE id=1",
                "UPDATE ddlcompat.t SET amount=78 WHERE id=2",
                "UPDATE ddlcompat.t SET amount=b'01100100' WHERE id=1",
            ])
        XCTAssertEqual(test.steps[13].sql, "INSERT INTO ddlcompat.t(id) VALUES(4)")
        XCTAssertFalse(test.steps.contains { $0.sql == "DELETE FROM ddlcompat.cv_integer WHERE id=3" })
        XCTAssertTrue(test.steps.contains { $0.sql == "DELETE FROM ddlcompat.cv_bit WHERE id=3" })
        let final = try XCTUnwrap(test.finalObservations)
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(checks["converted-decimal-index-values"], "1\t56.00\n2\t34.00")
        XCTAssertEqual(checks["decimal-default-insert"], "3.50")
        XCTAssertEqual(checks["double-update-and-fractional-row"], "1\t56\n2\t78\n3\t3.5")
        XCTAssertEqual(checks["fractional-row-retained-after-integer-conversion"], "1")
        XCTAssertEqual(checks["bit-values-after-delete"], "1\t56\n2\t78")
        XCTAssertEqual(checks["final-integer-values-and-default"], "1\t100\n2\t78\n4\t5")
        let decimals = try XCTUnwrap(final.checks.first { $0.id == "converted-decimal-index-values" })
        XCTAssertTrue(decimals.check.sql.contains("FORCE INDEX(by_n)"))
        XCTAssertThrowsError(try decimals.result([decimals.id: "1\t12.00\n2\t34.00"], engine: "MyISAM", role: "target"))
    }

}
