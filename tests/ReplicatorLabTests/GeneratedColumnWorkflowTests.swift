import XCTest

@testable import ReplicatorLabCore

final class GeneratedColumnWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int, retained: [(String, Int)], phases count: Int,
        restarts: [Int]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.count, count)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }, restarts)
        XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
        XCTAssertTrue(
            test.steps.allSatisfy { $0.sql == $0.sqlTransactional && $0.transactions == 1 && $0.assertionID == nil })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + retained.map { "ddlcompat." + $0.0 }.joined(separator: ",")])
        var start = originalCount
        for (table, length) in retained {
            XCTAssertEqual(
                test.steps[start..<start + length].map(\.sql),
                test.steps.prefix(length).map {
                    $0.sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table)
                })
            XCTAssertTrue(test.steps[start..<start + length].allSatisfy { !$0.restartBefore })
            start += length
        }
        XCTAssertEqual(start, test.steps.count)
        for check in final.checks {
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([check.id: check.check.expected], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([check.id: "wrong"], engine: engine, role: "target"))
            }
        }
        return final
    }

    func testBasicValuesRetainMigrationRowsAndStorageForms() throws {
        let test = DDLCompatibilityCases.generatedColumns
        let final = try verify(
            test, originalCount: 7,
            retained: [("gc_inserted", 2), ("gc_updated", 3), ("gc_added", 5), ("gc_deleted", 6)],
            phases: 1, restarts: [])
        XCTAssertEqual(test.steps.count, 23)
        XCTAssertEqual(test.steps[6].sql, "DELETE FROM ddlcompat.t WHERE id=2")
        let values = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(values["generated-insert-values"], "1\t7\t14\t8\n2\tNULL\tNULL\tNULL")
        XCTAssertEqual(values["generated-update-values"], "1\t9\t18\t10")
        XCTAssertEqual(values["added-column-existing-values"], "1\t9\t18\t10\t11\n2\tNULL\tNULL\tNULL\tNULL")
        XCTAssertEqual(values["insert-after-add"], "3\t11\t22\t12\t13")
        XCTAssertEqual(values["generated-delete-retains-null"], "2\tNULL\tNULL\tNULL\tNULL\n3\t11\t22\t12\t13")
        XCTAssertEqual(values["final-row-count"], "1")
        XCTAssertEqual(values["final-generated-values"], "3\t11\t22\t12\t13")
        XCTAssertEqual(values["initial-storage-forms"], "doubled\tSTORED GENERATED\nadded\tVIRTUAL GENERATED")
        XCTAssertEqual(
            values["added-storage-form"],
            "doubled\tSTORED GENERATED\nadded\tVIRTUAL GENERATED\nnext_value\tSTORED GENERATED")
        XCTAssertEqual(final.checks.count, 9)
        let nullCheck = try XCTUnwrap(final.checks.first { $0.id == "generated-delete-retains-null" })
        XCTAssertThrowsError(
            try nullCheck.result([nullCheck.id: "3\t11\t22\t12\t13"], engine: "MyISAM", role: "target"))
    }

    func testExpressionsKeepReplayBoundaryAndBothRestarts() throws {
        let test = DDLCompatibilityCases.generatedExpressions
        let final = try verify(
            test, originalCount: 8,
            retained: [("ge_initial", 2), ("ge_updated", 3), ("ge_added", 4), ("ge_predicates", 5)],
            phases: 3, restarts: [2, 6])
        XCTAssertEqual(test.steps.count, 22)
        XCTAssertEqual(test.steps[2].sql, "UPDATE ddlcompat.t SET n=12,v='xyzx',d='2025-01-02' WHERE id=1")
        XCTAssertEqual(test.steps[5].sql, "CREATE TABLE ddlcompat.copy LIKE ddlcompat.t")
        XCTAssertEqual(test.steps[6].sql, "INSERT INTO ddlcompat.copy(id,n,v,d) VALUES(3,1,'xxone','2024-01-01')")
        XCTAssertEqual(test.steps[7].sql, "DELETE FROM ddlcompat.t WHERE id=1")
        XCTAssertTrue(final.replayResetSQL.contains(final.cleanup[0] + "; DROP DATABASE ddlcompat"))
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        XCTAssertEqual(phases.map { $0.steps.count }, [2, 4, 16])
        XCTAssertTrue(phases.allSatisfy { $0.checks.isEmpty })
        XCTAssertEqual(final.queries().count, 9)
    }

    func testExpressionObservationsKeepNullsBinaryDateAndCopiedIndex() throws {
        let final = try XCTUnwrap(DDLCompatibilityCases.generatedExpressions.finalObservations)
        let values = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(
            values["initial-expression-values"],
            "1\t3\t40\t6\txxa\tabc\t2026\t10\t1\t0\n2\t0\t0\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t1")
        XCTAssertEqual(values["initial-interval-values"], "1\t1\n2\t-1")
        XCTAssertEqual(values["initial-date-binary-and-negation"], "1\t2026-10-15\t0102\t1\n2\tNULL\t0102\tNULL")
        XCTAssertEqual(values["updated-expression-values"], "0\t0\t8\txyz\tyz\t2025\t12\t0")
        XCTAssertEqual(values["added-predicates-before-null-update"], "1\t1\t1\n2\t0\tNULL")
        XCTAssertEqual(values["predicate-input-update"], "1\t0\t0\t8\t12\t0\t0\t1\t1\n2\t1\t20\t2\t10\t1\t0\t1\t0")
        XCTAssertEqual(values["like-copy-generated-values"], "3\t1\t20\t2024-01-02\t0102\t0\t1")
        XCTAssertEqual(values["final-row-after-delete"], "2\t1\t20\t2\t10\t1\t0\t1\t0")
        XCTAssertEqual(values["like-copy-generated-index"], "chosen\tBTREE")
    }
}
