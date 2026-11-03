import XCTest

@testable import ReplicatorLabCore

final class StoredObjectWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, database: String, total: Int,
        histories: [(Int, [(String, String)])]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(test.steps.count, total)
        XCTAssertTrue(
            test.steps.allSatisfy {
                !$0.restartBefore && $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil
            })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        XCTAssertEqual(final.databases, ["ddlcompat", database])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE " + database])
        XCTAssertEqual(test.steps[6].sql, "CREATE DATABASE " + database + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        var offset = 7
        for (length, mapping) in histories {
            let expected = test.steps.prefix(length).map { step in
                mapping.reduce(step.sql) { sql, pair in
                    sql.replacingOccurrences(of: "ddlcompat." + pair.0, with: database + "." + pair.1)
                }
            }
            XCTAssertEqual(test.steps[offset..<offset + length].map(\.sql), expected)
            XCTAssertTrue(expected.allSatisfy { !$0.contains("ddlcompat.") })
            offset += length
        }
        XCTAssertEqual(offset, total)
        XCTAssertTrue(final.queries().allSatisfy { $0.preserveWhitespace && $0.sql.contains("SELECT ") })
        return final
    }
    private func check(_ final: DDLFinalObservations, _ id: String, _ sql: String, _ expected: String) throws {
        let c = try XCTUnwrap(final.checks.first { $0.id == id })
        XCTAssertEqual(c.check.sql, sql)
        XCTAssertEqual(c.check.expected, expected)
        for engine in ["InnoDB", "MyISAM"] {
            _ = try c.result([id: expected], engine: engine, role: "target")
            XCTAssertThrowsError(try c.result([id: "wrong"], engine: engine, role: "target"))
        }
    }
    func testViewsRetainEachDefinitionAndOriginalDatabaseAbsence() throws {
        let test = DDLCompatibilityCases.viewLifecycle
        let final = try verify(
            test, database: "stored_view_results", total: 19,
            histories: [
                (3, [("t", "sv_initial_base"), ("v", "sv_initial")]),
                (4, [("t", "sv_replaced_base"), ("v", "sv_replaced")]),
                (5, [("t", "sv_altered_base"), ("v", "sv_altered")]),
            ])
        XCTAssertEqual(test.steps[5].sql, "DROP VIEW ddlcompat.v")
        XCTAssertTrue(test.steps[3].sql.hasPrefix("CREATE OR REPLACE SQL SECURITY INVOKER VIEW"))
        XCTAssertTrue(test.steps[4].sql.hasPrefix("ALTER SQL SECURITY INVOKER VIEW"))
        try check(final, "original-view-rows", "SELECT * FROM stored_view_results.sv_initial", "1\t7")
        try check(final, "replaced-view-rows", "SELECT * FROM stored_view_results.sv_replaced", "1\t8")
        try check(final, "altered-view-rows", "SELECT * FROM stored_view_results.sv_altered", "1\t9")
        try check(
            final, "original-views-dropped",
            "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'", "0")
        try check(
            final, "retained-view-security",
            "SELECT TABLE_NAME,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='stored_view_results' ORDER BY TABLE_NAME",
            "sv_altered\tINVOKER\nsv_initial\tINVOKER\nsv_replaced\tINVOKER")
    }
    func testRoutinesKeepCompoundBodyReferencesAndReadOnlyFinalChecks() throws {
        let test = DDLCompatibilityCases.routineLifecycle
        let final = try verify(
            test, database: "stored_routine_results", total: 12,
            histories: [
                (2, [("t", "sr_created_base"), ("p", "sr_created_p")]),
                (3, [("t", "sr_function_base"), ("p", "sr_function_p"), ("f", "sr_function_f")]),
            ])
        XCTAssertEqual(
            test.steps[1].sql,
            "CREATE PROCEDURE ddlcompat.p(IN k INT) SQL SECURITY INVOKER BEGIN DECLARE v INT; SET v=k+1; INSERT INTO ddlcompat.t VALUES(k,v); END"
        )
        XCTAssertEqual(test.steps[3].sql, "CALL ddlcompat.p(1)")
        XCTAssertEqual(test.steps[4].sql, "DROP PROCEDURE ddlcompat.p")
        XCTAssertEqual(test.steps[5].sql, "DROP FUNCTION ddlcompat.f")
        XCTAssertEqual(test.steps.filter { $0.sql.hasPrefix("CALL ") }.count, 1)
        try check(
            final, "procedure-create-does-not-execute", "SELECT COUNT(*) FROM stored_routine_results.sr_created_base",
            "0")
        try check(final, "retained-function-result", "SELECT stored_routine_results.sr_function_f(7)", "8")
        try check(final, "original-call-result", "SELECT * FROM ddlcompat.t", "1\t2")
        try check(
            final, "original-routines-dropped",
            "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'", "0")
        try check(
            final, "retained-routine-metadata",
            "SELECT ROUTINE_NAME,ROUTINE_TYPE,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='stored_routine_results' ORDER BY ROUTINE_NAME",
            "sr_created_p\tPROCEDURE\tINVOKER\nsr_function_f\tFUNCTION\tINVOKER\nsr_function_p\tPROCEDURE\tINVOKER")
    }
    func testSourceBatchKeepsCompoundCreateInsideOneClientRequest() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.routineLifecycle.steps))
        let writes = phases[0].writes(transactional: false)
        let queries = try LabSQLPhase.queries(
            writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
        let batch = LabSQLBatch(queries: queries)
        let input = try LabSQLInput(batch.statement, resetGTID: false, script: false, delimiter: "_routine_end")
        XCTAssertEqual(input.arguments, ["--delimiter=_routine_end"])
        let sql = String(decoding: input.bytes, as: UTF8.self)
        for write in writes.filter({ $0.sql.contains("CREATE PROCEDURE") }) {
            XCTAssertTrue(sql.contains(write.sql + "; SHOW WARNINGS"))
        }
        XCTAssertTrue(sql.contains("BEGIN DECLARE v INT; SET v=k+1; INSERT INTO ddlcompat.t VALUES(k,v); END"))
        XCTAssertEqual(sql.components(separatedBy: "\n_routine_end\n").count, 2)
        XCTAssertEqual(queries.count, writes.count * 4)
        XCTAssertTrue(queries.contains { $0.sql.contains("SELECT '") } == false)
    }
}
