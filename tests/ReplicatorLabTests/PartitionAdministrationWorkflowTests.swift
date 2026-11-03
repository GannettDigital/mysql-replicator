import XCTest

@testable import ReplicatorLabCore

final class PartitionAdministrationWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int, sizes: [Int], restarts: [Int],
        transactions: Int, retained: [([Int], [(String, String)])]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, sizes)
        XCTAssertEqual(test.steps.count, sizes.reduce(0, +))
        XCTAssertEqual(test.steps.reduce(0) { $0 + $1.transactions }, transactions)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, restarts)
        XCTAssertTrue(test.nativeInnoDB)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(
            test.steps.allSatisfy { $0.sql == $0.sqlTransactional && $0.checks.isEmpty && $0.assertionID == nil })
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        var offset = originalCount
        for (numbers, replacements) in retained {
            let actual = Array(test.steps[offset..<offset + numbers.count])
            let expected = numbers.map { number in
                replacements.reduce(test.steps[number - 1].sql) { sql, names in
                    sql.replacingOccurrences(of: "ddlcompat." + names.0, with: "ddlcompat." + names.1)
                }
            }
            XCTAssertEqual(actual.map(\.sql), expected)
            XCTAssertEqual(actual.map(\.transactions), numbers.map { test.steps[$0 - 1].transactions })
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore })
            offset += numbers.count
        }
        XCTAssertEqual(offset, test.steps.count)
        let names = retained.flatMap { $0.1.map { $0.1 } }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(Set(names).isDisjoint(with: ["t", "stage", "copy", "sub"]))
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + names.map { "ddlcompat." + $0 }.joined(separator: ",")])
        return final
    }

    private func check(_ final: DDLFinalObservations, _ id: String, _ sql: String, _ expected: String) throws {
        let observation = try XCTUnwrap(final.checks.first { $0.id == id })
        XCTAssertEqual(observation.check.sql, sql)
        XCTAssertEqual(observation.check.expected, expected)
        for engine in ["InnoDB", "MyISAM"] {
            _ = try observation.result([id: expected], engine: engine, role: "target")
            XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
        }
    }

    func testKeyAlgorithmsRetainPlacementAndIndependentSubpartitionSequences() throws {
        let test = DDLCompatibilityCases.partitionKeyAlgorithm
        let names = ["ka_seed", "ka_truncated", "ka_added", "ka_coalesced", "ka_algorithm_two"]
        var retained = names.enumerated().map { (Array(1...($0.offset + 2)), [("t", $0.element)]) }
        retained += [(Array(10...11), [("sub", "ka_sub_seed")]), (Array(10...12), [("sub", "ka_sub_reorganized")])]
        let final = try verify(
            test, originalCount: 13, sizes: [3, 5, 4, 26], restarts: [4, 9, 13], transactions: 38, retained: retained)
        XCTAssertEqual(test.steps[5].sql, "ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=2(id) PARTITIONS 4")
        XCTAssertEqual(test.steps[6].sql, "ALTER TABLE ddlcompat.t PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 4")
        XCTAssertEqual(test.steps[7].sql, "CREATE TABLE ddlcompat.copy LIKE ddlcompat.t")
        try check(
            final, "algorithm-one-placement",
            "SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.ka_seed PARTITION(p0)", "1,5,9,13")
        try check(final, "truncated-count-sum", "SELECT COUNT(*),SUM(n) FROM ddlcompat.ka_truncated", "12\t1080")
        try check(final, "copied-count-sum", "SELECT COUNT(*),SUM(n) FROM ddlcompat.copy", "12\t1080")
        try check(final, "initial-subpartition-placement", "SELECT id FROM ddlcompat.ka_sub_seed PARTITION(psp0)", "1")
        try check(
            final, "updated-subpartition-rows", "SELECT id,n FROM ddlcompat.sub ORDER BY id",
            "1\t11\n2\t21\n3\t31\n4\t41")
        try check(final, "reorganized-subpartition-placement", "SELECT id FROM ddlcompat.sub PARTITION(lowsp0)", "1")
    }

    func testUncheckedExchangeRetainsMisplacedRowsAndBothTables() throws {
        let test = DDLCompatibilityCases.partitionExchangeUnchecked
        let names = [
            "ex_seed", "ex_misplaced", "ex_restored", "ex_stage_empty", "ex_stage_seeded", "ex_exchanged", "ex_updated",
            "ex_stage_deleted", "ex_inserted",
        ]
        let retained = names.enumerated().map {
            (Array(1...($0.offset + 4)), [("t", $0.element), ("stage", $0.element + "_stage")])
        }
        let final = try verify(
            test, originalCount: 13, sizes: [5, 4, 76], restarts: [6, 10], transactions: 85, retained: retained)
        XCTAssertEqual(
            test.steps[4].sql,
            "ALTER TABLE ddlcompat.t EXCHANGE PARTITION p WITH TABLE ddlcompat.stage WITHOUT VALIDATION")
        XCTAssertEqual(test.steps.prefix(13).filter { $0.sql.contains("EXCHANGE PARTITION") }.count, 3)
        try check(final, "misplaced-partition-row", "SELECT id,n FROM ddlcompat.ex_misplaced PARTITION(p)", "20\t200")
        try check(final, "misplaced-row-pruned", "SELECT COUNT(*) FROM ddlcompat.ex_misplaced WHERE id=20", "0")
        try check(final, "misplaced-stage-row", "SELECT id FROM ddlcompat.ex_misplaced_stage", "1")
        try check(final, "exchange-back-rows", "SELECT id FROM ddlcompat.ex_restored ORDER BY id", "1\n11")
        try check(final, "updated-rows", "SELECT id,n FROM ddlcompat.ex_updated ORDER BY id", "2\t21\n11\t110")
        try check(final, "truncated-final-rows", "SELECT id,n FROM ddlcompat.t", "11\t110")
    }

    func testMaintenanceKeepsFiveUnloggedOperationsAndAllPriorStates() throws {
        let test = DDLCompatibilityCases.partitionMaintenance
        let names = ["pm_seed", "pm_rebuilt", "pm_analyzed", "pm_optimized", "pm_repaired", "pm_checked", "pm_local"]
        let final = try verify(
            test, originalCount: 9, sizes: [5, 3, 36], restarts: [6, 9], transactions: 39,
            retained: names.enumerated().map { (Array(1...($0.offset + 2)), [("t", $0.element)]) })
        XCTAssertEqual(test.steps[6].sql, "ALTER TABLE ddlcompat.t CHECK PARTITION ALL EXTENDED")
        XCTAssertEqual(test.steps[7].sql, "ALTER TABLE ddlcompat.t ANALYZE PARTITION LOCAL ALL")
        XCTAssertEqual(test.steps.filter { $0.transactions == 0 }.count, 5)
        XCTAssertEqual(test.steps.prefix(9).map(\.transactions), [1, 1, 1, 1, 1, 1, 0, 0, 1])
        try check(final, "updated-rows", "SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")
        for name in names {
            try check(
                final, name.replacingOccurrences(of: "_", with: "-") + "-rows",
                "SELECT id,n FROM ddlcompat." + name + " ORDER BY id", "1\t10\n2\t20")
        }
    }

    func testUnloggedValidationRejectsMissingResultsGTIDsAndPositionChanges() throws {
        let phase = DDLExecutionPhase(id: "unlogged", steps: [.init("CHECK TABLE t", transactions: 0)])
        let start = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        func result(_ end: Boundary, _ gtids: String = "") -> LabSQLPhase.Result {
            .init(write: .init(id: "check", sql: "CHECK TABLE t"), start: start, end: end, gtids: gtids, warnings: "")
        }
        XCTAssertEqual(try phase.validateUnlogged([result(start)]), 1)
        XCTAssertThrowsError(try phase.validateUnlogged([]))
        XCTAssertThrowsError(try phase.validateUnlogged([result(start, "uuid:2")]))
        XCTAssertThrowsError(
            try phase.validateUnlogged([result(.init(file: start.file, position: 100, gtids: "uuid:1-2"))]))
        XCTAssertThrowsError(
            try phase.validateUnlogged([result(.init(file: start.file, position: 101, gtids: start.gtids))]))
        XCTAssertThrowsError(
            try phase.validateUnlogged([result(.init(file: "binlog.000002", position: 100, gtids: start.gtids))]))
        let logged = DDLExecutionPhase(id: "logged", steps: [.init("INSERT INTO t VALUES(1)")])
        XCTAssertEqual(
            try logged.validateUnlogged([result(.init(file: start.file, position: 200, gtids: "uuid:1-2"), "uuid:2")]),
            0)
    }
}
