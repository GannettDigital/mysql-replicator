import XCTest

@testable import ReplicatorLabCore

final class DMLExecutionWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.identifierCase }

    func testBatchesCountGTIDsRatherThanClientRequests() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.prepare.writes.count, 4)
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.writes.count, 10)
        XCTAssertEqual(plan.body.transactions, [1, 2, 3, 2, 1, 1, 2, 1, 2, 3])
        XCTAssertEqual(plan.body.transactionCount, 18)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(try plan.body.validate(results(plan.body)), plan.body.transactions)
        XCTAssertTrue(results(plan.body).contains { $0.gtids.contains("-") })
        XCTAssertThrowsError(try plan.body.validate(Array(results(plan.body).dropLast())))
        var wrong = results(plan.body)
        let result = wrong[1]
        wrong[1] = .init(write: result.write, start: result.start, end: result.end, gtids: "uuid:3", warnings: "")
        XCTAssertThrowsError(try plan.body.validate(wrong))
        wrong = results(plan.body)
        wrong[0] = .init(
            write: .init(id: "wrong", sql: result.write.sql), start: result.start, end: result.end, gtids: "uuid:2",
            warnings: "")
        XCTAssertThrowsError(try plan.body.validate(wrong))
    }

    func testProgressRequiresCountersAndExactAppliedBoundary() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 10, "ddlApplied": 2, "rowsApplied": 3]
        let end = Boundary(file: "binlog.000001", position: 3000, gtids: "uuid:1-32")
        var after: [String: Any] = [
            "transactionsApplied": 32, "ddlApplied": 14, "rowsApplied": 17, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "3000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 24  // Fourteen requests do not mean fourteen GTIDs.
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 32
        after["appliedPosition"] = ["file": end.file, "position": "2999"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["appliedPosition"] = ["file": end.file, "position": "3000"]
        after["appliedGTIDSet"] = "uuid:1-31"
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["appliedGTIDSet"] = end.gtids
        after["transactionsApplied"] = 33
        after["ddlApplied"] = 15
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: true))
        after.removeValue(forKey: "rowsApplied")
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: true))
    }

    func testUnsupportedCasePrerequisitesAreRejected() throws {
        let workflow = try XCTUnwrap(fixture.workflow)
        var test = fixture
        test.setup = "SET @special=1"
        XCTAssertThrowsError(try workflow.plan(test))
        test = fixture
        test.orderBy = "Value"
        XCTAssertThrowsError(try workflow.plan(test))
        test = fixture
        test.replicatedReplacement = "another-case"
        XCTAssertThrowsError(try workflow.plan(test))
        var phases = fixture.phases
        phases[0].expectsJSONDiff = true
        XCTAssertThrowsError(try workflow.plan(.init(id: fixture.id, definition: fixture.definition, phases: phases)))
        let invalid = DMLExecutionWorkflow(
            title: workflow.title, histories: [workflow.histories[0], workflow.histories[0]],
            phaseTransactions: workflow.phaseTransactions, predicateIDs: workflow.predicateIDs,
            additionalChecks: workflow.additionalChecks, expectedDDL: workflow.expectedDDL,
            expectedRows: workflow.expectedRows)
        XCTAssertThrowsError(try invalid.plan(fixture))
        let missingCounts = DMLExecutionWorkflow(
            title: workflow.title, histories: workflow.histories, phaseTransactions: [1],
            predicateIDs: workflow.predicateIDs, additionalChecks: workflow.additionalChecks,
            expectedDDL: workflow.expectedDDL, expectedRows: workflow.expectedRows)
        XCTAssertThrowsError(try missingCounts.plan(fixture))
    }

    func testOrderingNeedsExplicitMatchingFixedExpression() throws {
        var ordinal = try XCTUnwrap(fixture.workflow)
        ordinal.order = .idOrdinal
        var test = fixture
        XCTAssertThrowsError(try ordinal.plan(test))
        test.orderBy = "id+0"
        XCTAssertThrowsError(try XCTUnwrap(fixture.workflow).plan(test))
        XCTAssertNoThrow(try ordinal.plan(test))
        test.orderBy = "id DESC"
        XCTAssertThrowsError(try ordinal.plan(test))
        XCTAssertNil(DMLExecutionWorkflow.Order(rawValue: "id DESC"))
        XCTAssertNil(DMLExecutionWorkflow.Order(rawValue: "Value"))
        XCTAssertEqual(DMLExecutionWorkflow.Order.id.rawValue, "id")
        XCTAssertEqual(DMLExecutionWorkflow.Order.idOrdinal.rawValue, "id+0")
    }

    func testEveryWriteKeepsSessionSetupAndOriginalAutocommitScripts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for batch in [plan.prepare, plan.body, plan.cleanup] {
            let queries = try LabSQLPhase.queries(
                batch.writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
            for (index, write) in batch.writes.enumerated() {
                let sql = queries[index * 4].sql
                XCTAssertTrue(sql.hasPrefix(LabProfile.forward.session))
                XCTAssertTrue(sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                XCTAssertFalse(write.sql.contains("BEGIN"))
                XCTAssertFalse(write.sql.contains("COMMIT"))
                XCTAssertFalse(write.checkWarnings)
            }
        }
        XCTAssertTrue(plan.prepare.writes.allSatisfy { !$0.sql.contains("USE ") })
        XCTAssertTrue(plan.body.writes.allSatisfy { $0.sql.hasPrefix("USE poc; ") })
    }

    private func results(_ batch: DMLExecutionWorkflow.Batch) -> [LabSQLPhase.Result] {
        var sequence = 1
        return zip(batch.writes, batch.transactions).map { write, count in
            let start = Boundary(file: "binlog.000001", position: UInt64(sequence * 100), gtids: "uuid:1-\(sequence)")
            let first = sequence + 1
            sequence += count
            let end = Boundary(file: start.file, position: UInt64(sequence * 100), gtids: "uuid:1-\(sequence)")
            return .init(
                write: write, start: start, end: end, gtids: "uuid:\(first)" + (count == 1 ? "" : "-\(sequence)"),
                warnings: "")
        }
    }
}
