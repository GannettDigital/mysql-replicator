import XCTest

@testable import ReplicatorLabCore

final class DDLFinalObservationsTests: XCTestCase {
    func testMultiTableRetainsRestartOperationsAndFinalResults() throws {
        let test = DDLCompatibilityCases.multiTableDDL
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 30)
        XCTAssertEqual(phases.count, 6)
        XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
        XCTAssertEqual(
            phases.filter { $0.steps[0].restartBefore }.map { $0.steps[0].sql },
            [
                "RENAME TABLE ddlcompat.t TO otherdb.moved",
                "RENAME TABLE otherdb.moved TO ddlcompat.spare,ddlcompat.u TO otherdb.moved,ddlcompat.spare TO ddlcompat.u",
                "DROP TABLE ddlcompat.u,otherdb.moved,otherdb.copy RESTRICT",
                "DROP TABLE IF EXISTS ddlcompat.u,otherdb.moved,otherdb.absent CASCADE",
                "INSERT INTO ddlcompat.u VALUES(4,4.25)",
            ])
        XCTAssertEqual(final.databases, ["ddlcompat", "otherdb"])
        XCTAssertEqual(
            Set(final.checks.map(\.id)),
            [
                "moved-table-encoding", "moved-row", "updated-moved-row", "swapped-integer-table",
                "swapped-text-table", "like-copy-row", "like-copy-empty", "dropped-destination-tables",
                "old-and-temporary-names-absent", "reused-name-row", "reused-name-definition",
            ])
        let expected = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        for check in final.checks {
            _ = try check.result(expected, engine: "MyISAM", role: "target")
        }
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.mt_swap_u,otherdb.mt_moved,otherdb.mt_updated,otherdb.mt_swap_moved,otherdb.mt_copy,otherdb.mt_empty_copy"
            ])
        XCTAssertTrue(test.steps.allSatisfy { $0.sqlTransactional == $0.sql && $0.transactions == 1 })
        XCTAssertNil(DDLCompatibilityCases.crossSchemaRelationships.finalObservations)
    }

    func testFinalObservationsCannotHideChecksOrDuplicateNames() throws {
        let check = DDLFinalObservations.Observation(id: "row", check: .init("SELECT v FROM t", "1"))
        let phase = DDLExecutionPhase(id: "write", steps: [.init("INSERT INTO t VALUES(1)")])
        let valid = DDLFinalObservations(checks: [check], databases: ["ddlcompat"], cleanup: [])
        try valid.validate([phase])
        XCTAssertThrowsError(try valid.validate([]))
        XCTAssertThrowsError(
            try valid.validate([
                .init(id: "hidden", steps: [.init("SELECT 1", [.init("SELECT 1", "1")])])
            ]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [check, check], databases: ["ddlcompat"], cleanup: []).validate([phase]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [], databases: ["ddlcompat"], cleanup: []).validate([phase]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [check], databases: ["ddlcompat", "ddlcompat"], cleanup: []).validate([
                phase
            ]))
    }

    func testFinalQueryMismatchIdentifiesAssertionAndRole() throws {
        let check = DDLFinalObservations.Observation(
            id: "moved-row", check: .init("SELECT id,n FROM otherdb.moved", "1\tchanged"))
        XCTAssertThrowsError(try check.result(["moved-row": "1\tfirst"], engine: "MyISAM", role: "target")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("moved-row/target"))
            XCTAssertTrue(message.contains("SELECT id,n FROM otherdb.moved"))
            XCTAssertTrue(message.contains("expected 1\tchanged"))
        }
        XCTAssertThrowsError(try check.result([:], engine: "MyISAM", role: "target"))
        let plan = DDLFinalObservations(checks: [check], databases: ["otherdb"], cleanup: [])
        XCTAssertEqual(plan.queries[0].name, "moved-row")
        XCTAssertTrue(plan.queries[0].preserveWhitespace)
        XCTAssertTrue(plan.queries[0].sql.contains("SET NAMES utf8mb4"))
    }
}
