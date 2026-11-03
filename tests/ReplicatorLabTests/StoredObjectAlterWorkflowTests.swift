import XCTest

@testable import ReplicatorLabCore

final class StoredObjectAlterWorkflowTests: XCTestCase {
    func testRetainedHistoriesPreserveDependenciesRestartsAndCleanup() throws {
        let test = DDLCompatibilityCases.storedObjects
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [3, 5, 6, 65])
        XCTAssertEqual(test.steps.count, 79)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [4, 9, 15])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil })
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        XCTAssertEqual(final.databases, ["ddlcompat", "stored_alter_results"])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE stored_alter_results"])
        XCTAssertEqual(
            test.steps[15].sql, "CREATE DATABASE stored_alter_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        let stems = [
            "sa_original", "sa_procedure", "sa_function", "sa_called", "sa_local", "sa_second_view", "sa_inserted",
            "sa_cascaded", "sa_updated",
        ]
        var offset = 16
        var names: [String] = []
        for (index, stem) in stems.enumerated() {
            let length = index + 3
            var mapping = [("t", stem + "_t"), ("p", stem + "_p"), ("f", stem + "_f")]
            if length >= 7 { mapping.append(("v", stem + "_v")) }
            if length >= 8 { mapping.append(("v2", stem + "_v2")) }
            // Replace the longer view name first, so v cannot consume v2.
            let sorted = mapping.sorted { $0.0.count > $1.0.count }
            let expected = test.steps.prefix(length).map { step in
                sorted.reduce(step.sql) { sql, names in
                    sql.replacingOccurrences(of: "ddlcompat." + names.0, with: "stored_alter_results." + names.1)
                }
            }
            let actual = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(actual.map(\.sql), expected)
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore && !$0.sql.contains("ddlcompat.") })
            names += mapping.map { $0.1 }
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertEqual(names.count, 36)
        XCTAssertEqual(Set(names).count, 36)
    }

    func testOriginalDropSQLAndRoutineBodiesRemainFirst() {
        let steps = DDLCompatibilityCases.storedObjects.steps
        XCTAssertEqual(
            steps[1].sql,
            "CREATE DEFINER='root'@'localhost' PROCEDURE ddlcompat.p(IN k INT) MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'original' INSERT INTO ddlcompat.t VALUES(k,k+10)"
        )
        XCTAssertEqual(
            steps[3].sql,
            "ALTER PROCEDURE ddlcompat.p LANGUAGE SQL MODIFIES SQL DATA SQL SECURITY INVOKER COMMENT 'updated procedure'"
        )
        XCTAssertEqual(
            steps[4].sql, "ALTER FUNCTION ddlcompat.f READS SQL DATA SQL SECURITY INVOKER COMMENT 'updated function'")
        XCTAssertEqual(steps[11].sql, "DROP VIEW IF EXISTS ddlcompat.v,ddlcompat.v2,ddlcompat.absent CASCADE")
        XCTAssertEqual(steps[12].sql, "DROP PROCEDURE IF EXISTS ddlcompat.p")
        XCTAssertEqual(steps[13].sql, "DROP FUNCTION IF EXISTS ddlcompat.f")
        XCTAssertEqual(steps[14].sql, "DELETE FROM ddlcompat.t WHERE id=1")
    }

    func testAllOriginalPredicatesAndReadOnlyFinalObservationsRemain() throws {
        let final = try XCTUnwrap(DDLCompatibilityCases.storedObjects.finalObservations)
        let expected: [(String, String, String)] = [
            (
                "altered-procedure-metadata",
                "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_procedure_p'",
                "root@localhost\tINVOKER\tMODIFIES SQL DATA\tupdated procedure"
            ),
            (
                "altered-function-metadata",
                "SELECT DEFINER,SECURITY_TYPE,SQL_DATA_ACCESS,IS_DETERMINISTIC,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_alter_results' AND ROUTINE_NAME='sa_function_f'",
                "root@localhost\tINVOKER\tREADS SQL DATA\tYES\tupdated function"
            ),
            ("function-result", "SELECT stored_alter_results.sa_function_f(7)", "8"),
            ("procedure-call-rows", "SELECT * FROM stored_alter_results.sa_called_t", "1\t11"),
            (
                "local-view-metadata",
                "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_alter_results' AND TABLE_NAME='sa_local_v'",
                "root@localhost\tINVOKER\tLOCAL\tYES"
            ),
            (
                "insert-through-view-rows", "SELECT * FROM stored_alter_results.sa_inserted_t ORDER BY id",
                "1\t11\n2\t20"
            ),
            (
                "cascaded-view-metadata",
                "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION,IS_UPDATABLE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_alter_results' AND TABLE_NAME='sa_cascaded_v'",
                "root@localhost\tDEFINER\tCASCADED\tYES"
            ),
            (
                "update-through-view-rows", "SELECT * FROM stored_alter_results.sa_updated_v2 ORDER BY id",
                "1\t11\n2\t21"
            ),
            (
                "original-views-dropped",
                "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'", "0"
            ),
            (
                "original-routines-dropped",
                "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'", "0"
            ),
            ("original-delete-rows", "SELECT * FROM ddlcompat.t", "2\t21"),
        ]
        for (id, sql, value) in expected {
            let check = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([id: "wrong"], engine: engine, role: "target"))
            }
        }
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(final.checks.count, 20)
    }
}
