import XCTest

@testable import ReplicatorLabCore

final class ConditionalRoutineWorkflowTests: XCTestCase {
    func testHistoriesPreserveSourceTransactionsAndDropRecreateStates() throws {
        let test = DDLCompatibilityCases.conditionalRoutines
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 50)
        XCTAssertEqual(phases.map { $0.steps.count }, [3, 4, 43])
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [4, 8])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(
            test.profileExclusions,
            [
                .reverse: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
                .mysql57MyISAM: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
                .mysql57InnoDB: "5.7 sources do not support routine CREATE IF NOT EXISTS.",
            ])
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        XCTAssertEqual(final.databases, ["ddlcompat", "conditional_routine_results"])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE conditional_routine_results"])
        XCTAssertEqual(
            test.steps[10].sql, "CREATE DATABASE conditional_routine_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        let stems = [
            "cr_procedure_kept", "cr_function_kept", "cr_called", "cr_dropped", "cr_recreated", "cr_called_new",
        ]
        var offset = 11
        for (index, stem) in stems.enumerated() {
            let length = index + 4
            let expected = test.steps.prefix(length).map { step in
                ["t", "p", "f"].reduce(step.sql) { sql, name in
                    sql.replacingOccurrences(
                        of: "ddlcompat." + name, with: "conditional_routine_results." + stem + "_" + name)
                }
            }
            let actual = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(actual.map(\.sql), expected)
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore && !$0.sql.contains("ddlcompat.") })
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertTrue(test.steps[1].sql.contains("COMMENT 'original'"))
        XCTAssertTrue(test.steps[3].sql.contains("'root'@'%'"))
        XCTAssertTrue(test.steps[3].sql.contains("COMMENT 'replacement'"))
        XCTAssertTrue(test.steps[3].sql.contains("k+999"))
        XCTAssertEqual(test.steps[6].sql, "DROP PROCEDURE ddlcompat.p")
        XCTAssertTrue(test.steps[7].sql.contains("SQL SECURITY INVOKER"))
        XCTAssertTrue(test.steps[7].sql.contains("k+20"))
    }

    func testJournalSelectionUsesCapturedGTIDsDespiteServerSQLFormatting() throws {
        let steps = DDLCompatibilityCases.conditionalRoutines.steps
        let start = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        let writes = steps.enumerated().map { index, step in
            LabSQLPhase.Result(
                write: .init(id: "statement-\(index)", sql: step.sql),
                start: start, end: start, gtids: "uuid:\(index+1)", warnings: "")
        }
        let expected = "ddl_intents.gtid IN ('uuid:2','uuid:3','uuid:4','uuid:5','uuid:8')"
        let query = try ConditionalRoutineWorkflowEvidence.compatibilitySQL(writes)
        XCTAssertTrue(query.hasSuffix(expected))
        XCTAssertTrue(query.contains("mysql57-routine-create-if-not-exists"))
        XCTAssertTrue(try ConditionalRoutineWorkflowEvidence.skippedSQL(writes).hasSuffix(expected))
        XCTAssertTrue(try ConditionalRoutineWorkflowEvidence.skippedSQL(writes).contains("target_sql=''"))
        let rewritten = writes.map {
            LabSQLPhase.Result(
                write: .init(
                    id: $0.write.id,
                    sql:
                        "CREATE DEFINER=`root`@`localhost` FUNCTION IF NOT EXISTS `ddlcompat`.`f`() RETURNS int\nRETURN 1;"
                ), start: $0.start, end: $0.end, gtids: $0.gtids, warnings: "already exists")
        }
        XCTAssertEqual(try ConditionalRoutineWorkflowEvidence.compatibilitySQL(rewritten), query)
        XCTAssertFalse(query.contains("CONVERT("))
        XCTAssertThrowsError(try ConditionalRoutineWorkflowEvidence.compatibilitySQL([]))
        var missing = writes
        missing[3] = .init(write: writes[3].write, start: start, end: start, gtids: "", warnings: "")
        XCTAssertThrowsError(try ConditionalRoutineWorkflowEvidence.compatibilitySQL(missing))
        missing[3] = .init(write: writes[3].write, start: start, end: start, gtids: "uuid:4-5", warnings: "")
        XCTAssertThrowsError(try ConditionalRoutineWorkflowEvidence.skippedSQL(missing))
    }

    func testAllSixOriginalPredicatesRemainAndFinalChecksDoNotCallProcedures() throws {
        let final = try XCTUnwrap(DDLCompatibilityCases.conditionalRoutines.finalObservations)
        let expected: [(String, String, String)] = [
            (
                "existing-procedure-metadata",
                "SELECT DEFINER,SECURITY_TYPE,ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_procedure_kept_p'",
                "root@localhost\tDEFINER\toriginal"
            ),
            ("existing-function-result", "SELECT conditional_routine_results.cr_function_kept_f(7)", "8"),
            (
                "existing-function-metadata",
                "SELECT DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='conditional_routine_results' AND ROUTINE_NAME='cr_function_kept_f'",
                "root@localhost\tDEFINER"
            ),
            ("original-procedure-call-rows", "SELECT * FROM conditional_routine_results.cr_called_t", "1\t11"),
            (
                "recreated-procedure-call-rows",
                "SELECT * FROM conditional_routine_results.cr_called_new_t ORDER BY id", "1\t11\n2\t22"
            ),
            ("final-insert-rows", "SELECT * FROM ddlcompat.t ORDER BY id", "1\t11\n2\t22\n3\t8"),
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
        XCTAssertEqual(final.checks.count, 14)
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(final.checks.first { $0.id == "procedure-absent-after-drop" }?.check.expected, "0")
        XCTAssertEqual(final.checks.first { $0.id == "function-survives-procedure-drop" }?.check.expected, "1")
        XCTAssertEqual(
            final.checks.first { $0.id == "recreated-procedure-metadata" }?.check.expected, "root@localhost\tINVOKER")
    }
}
