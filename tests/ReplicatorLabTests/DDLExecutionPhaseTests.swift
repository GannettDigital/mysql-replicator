import XCTest

@testable import ReplicatorLabCore

final class DDLExecutionPhaseTests: XCTestCase {
    func testPlannerRejectsHiddenObservationsRestartsAndAssertions() throws {
        typealias Step = DDLCompatibilityCases.Step
        let end = Step("UPDATE t SET v=2", phaseEnd: "updated-rows")
        XCTAssertThrowsError(
            try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", [.init("SELECT v FROM t", "1")]), end]))
        XCTAssertThrowsError(
            try DDLExecutionPhase.plan([
                Step("CREATE TABLE t(v INT)"), Step("INSERT INTO t VALUES(1)", restartBefore: true), end,
            ]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", assertionID: "insert"), end]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([end, Step("DELETE FROM t")]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([end, end]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([Step("SELECT 1", phaseEnd: "../escape")]))
        XCTAssertNil(try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", restartBefore: true)]))
        XCTAssertNil(try DDLExecutionPhase.plan([]))
    }

    func testWritesResetAutoIncrementAndRetainTransactionalSQL() throws {
        let phase = DDLExecutionPhase(
            id: "transaction",
            steps: [
                .init(
                    "INSERT INTO t VALUES(1)", sqlTransactional: "BEGIN; INSERT INTO t VALUES(1); COMMIT",
                    phaseEnd: "transaction")
            ])
        XCTAssertTrue(phase.writes(transactional: true)[0].sql.hasSuffix("BEGIN; INSERT INTO t VALUES(1); COMMIT"))
        XCTAssertFalse(phase.writes(transactional: false)[0].sql.contains("COMMIT"))
        let keys = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.alterColumnKeys.steps))
        let writes = keys.flatMap { $0.writes(transactional: false) }
        for write in writes {
            XCTAssertTrue(
                write.sql.hasPrefix(
                    "SET SESSION auto_increment_increment=@@GLOBAL.auto_increment_increment,auto_increment_offset=@@GLOBAL.auto_increment_offset; "
                ))
        }
        XCTAssertTrue(writes[8].sql.contains("SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER"))
        XCTAssertFalse(writes[9].sql.contains("auto_increment_increment=3"))
    }

    func testBatchedExpectationsRetainWhitespaceFieldsAndEngineValues() throws {
        let phase = DDLExecutionPhase(
            id: "values",
            steps: [
                .init(
                    "SELECT 1",
                    [
                        .init("SELECT note FROM t", " a\t", myISAMExpected: " b\t"),
                        .init("SELECT a,b FROM t", "2", fields: [1]),
                    ], phaseEnd: "values")
            ])
        XCTAssertTrue(phase.queries.allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(phase.queries.map(\.name), ["check-1", "check-2"])
        let values = ["check-1": " b\t", "check-2": "ignored\t2"]
        XCTAssertEqual(try phase.observations(values, engine: "MyISAM", role: "target").count, 2)
        XCTAssertThrowsError(try phase.observations(values, engine: "InnoDB", role: "source"))
        XCTAssertThrowsError(try phase.observations(["check-1": "b"], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try phase.observations(["check-1": " b\t", "check-2": "missing-column"], engine: "MyISAM", role: "target"))
    }
}
