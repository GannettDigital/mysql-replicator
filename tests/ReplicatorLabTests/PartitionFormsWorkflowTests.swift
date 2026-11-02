import XCTest

@testable import ReplicatorLabCore

final class PartitionFormsWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int, sizes: [Int], restarts: [Int],
        retained: [([Int], [(String, String)])]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, sizes)
        XCTAssertEqual(test.steps.count, sizes.reduce(0, +))
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, restarts)
        XCTAssertTrue(test.nativeInnoDB)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(test.steps.allSatisfy { $0.transactions == 1 && $0.checks.isEmpty && $0.assertionID == nil })
        XCTAssertEqual(final.databases, ["ddlcompat"])
        var offset = originalCount
        for (numbers, replacements) in retained {
            let actual = Array(test.steps[offset..<offset + numbers.count])
            for transactional in [false, true] {
                let expected = numbers.map { number in
                    let step = test.steps[number - 1]
                    return replacements.reduce(transactional ? step.sqlTransactional : step.sql) { sql, names in
                        sql.replacingOccurrences(of: "ddlcompat." + names.0, with: "ddlcompat." + names.1)
                    }
                }
                XCTAssertEqual(actual.map { transactional ? $0.sqlTransactional : $0.sql }, expected)
            }
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore })
            offset += numbers.count
        }
        XCTAssertEqual(offset, test.steps.count)
        let names = retained.flatMap { $0.1.map { $0.1 } }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(Set(names).isDisjoint(with: ["t", "stage", "copy", "l", "c"]))
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + names.map { "ddlcompat." + $0 }.joined(separator: ",")])
        XCTAssertTrue(final.replayResetSQL.contains(final.cleanup[0]))
        return final
    }

    private func check(_ final: DDLFinalObservations, _ id: String, _ sql: String, _ expected: String) throws {
        let observation = try XCTUnwrap(final.checks.first { $0.id == id })
        XCTAssertEqual(observation.check.sql, sql)
        XCTAssertEqual(observation.check.expected, expected)
        for engine in ["MyISAM", "InnoDB"] {
            _ = try observation.result([id: expected], engine: engine, role: "target")
            XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
        }
    }

    func testHashFormsKeepImplicitKeyAndBothEngineAlternatives() throws {
        let test = DDLCompatibilityCases.partitionHashForms
        let names = ["pf_seed", "pf_added", "pf_coalesced", "pf_implicit_key", "pf_extra"]
        let final = try verify(
            test, originalCount: 7, sizes: [3, 3, 21], restarts: [4, 7],
            retained: names.enumerated().map { (Array(1...($0.offset + 2)), [("t", $0.element)]) })
        XCTAssertEqual(test.steps[4].sql, "ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2")
        XCTAssertTrue(test.steps[0].sql.contains("COMMENT='first' COMMENT='early'"))
        XCTAssertFalse(test.steps[0].sql.contains("ENGINE="))
        XCTAssertTrue(test.steps[0].sqlTransactional.contains("ENGINE='InnoDB' ENGINE=InnoDB"))
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        XCTAssertTrue(phases[0].writes(transactional: true)[0].sql.hasSuffix(test.steps[0].sqlTransactional))
        XCTAssertTrue(phases[0].writes(transactional: false)[0].sql.hasSuffix(test.steps[0].sql))
        try check(
            final, "added-partition-names",
            "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pf_added'",
            "early,late,p2,p3")
        try check(final, "updated-rows", "SELECT id,n FROM ddlcompat.t ORDER BY id", "1\t11\n2\t21")
    }

    func testSubpartitionHistoriesKeepExchangeAndCopyTablesSeparate() throws {
        let test = DDLCompatibilityCases.subpartitions
        let names = [
            "sp_seed", "sp_truncated", "sp_stage_empty", "sp_stage_seeded", "sp_exchanged", "sp_reorganized",
            "sp_inserted", "sp_dropped", "sp_added", "sp_seeded_new", "sp_updated", "sp_deleted", "sp_copy_empty",
            "sp_copy_seeded", "sp_copy_unpartitioned", "sp_list_key",
        ]
        let retained = names.enumerated().map { index, name -> ([Int], [(String, String)]) in
            let count = index + 2
            var replacements = [("t", name)]
            if count >= 4 { replacements.append(("stage", name + "_stage")) }
            if count >= 14 { replacements.append(("copy", name + "_copy")) }
            return (Array(1...count), replacements)
        }
        let final = try verify(
            test, originalCount: 18, sizes: [3, 4, 10, 153], restarts: [4, 8, 18], retained: retained)
        XCTAssertEqual(test.steps[2].sql, "ALTER TABLE ddlcompat.t TRUNCATE PARTITION p0sp1")
        XCTAssertEqual(
            test.steps[5].sql,
            "ALTER TABLE ddlcompat.t EXCHANGE PARTITION p0sp0 WITH TABLE ddlcompat.stage WITH VALIDATION")
        XCTAssertEqual(test.steps[13].sql, "CREATE TABLE ddlcompat.copy LIKE ddlcompat.t")
        try check(final, "truncated-rows", "SELECT id FROM ddlcompat.sp_truncated ORDER BY id", "2\n11\n12")
        try check(final, "exchanged-main-rows", "SELECT id FROM ddlcompat.sp_exchanged ORDER BY id", "4\n11\n12")
        try check(final, "exchanged-stage-rows", "SELECT id FROM ddlcompat.sp_exchanged_stage", "2")
        try check(final, "dropped-partition-rows", "SELECT id FROM ddlcompat.sp_dropped ORDER BY id", "4\n18")
        try check(
            final, "copied-rows", "SELECT id,n FROM ddlcompat.sp_copy_seeded_copy ORDER BY id",
            "4\t40\n18\t180\n22\t220")
        try check(final, "final-main-rows", "SELECT id,n FROM ddlcompat.t ORDER BY id", "4\t40\n18\t180\n22\t221")
        try check(
            final, "final-subpartition-names",
            "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
            "p4sp0,p4sp1,p18sp0,p18sp1,p22sp0,p22sp1")
        try check(
            final, "reorganized-subpartition-names",
            "SELECT GROUP_CONCAT(SUBPARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='sp_reorganized'",
            "p0sp0,p0sp1,a,b,c,d")
        for id in ["initial-subpartition-definitions", "final-subpartition-definitions"] {
            let query = try XCTUnwrap(final.checks.first { $0.id == id }).check.sql
            XCTAssertTrue(query.contains("SUBPARTITION_METHOD"))
            XCTAssertTrue(query.contains("SUBPARTITION_EXPRESSION"))
            XCTAssertTrue(query.contains("COUNT(*)"))
            XCTAssertTrue(query.contains("ORDER BY PARTITION_ORDINAL_POSITION"))
        }
    }

    func testExpressionHistoriesKeepFunctionsAndTupleRouting() throws {
        let test = DDLCompatibilityCases.partitionExpressions
        let final = try verify(
            test, originalCount: 13, sizes: [3, 6, 3, 24], restarts: [4, 10, 13],
            retained: [
                (Array(1...2), [("t", "pe_dates")]), (Array(1...3), [("t", "pe_reorganized")]),
                (Array(1...4), [("t", "pe_truncated")]), (Array(1...5), [("t", "pe_updated")]),
                (Array(7...8), [("l", "pe_list_seed")]), (Array(7...9), [("l", "pe_list_added")]),
                (Array(7...10), [("l", "pe_list_filled")]),
            ])
        XCTAssertTrue(test.steps[0].sql.contains("TO_DAYS('2026-01-01')"))
        XCTAssertTrue(test.steps[2].sql.contains("TO_DAYS('2027-01-01')"))
        XCTAssertTrue(test.steps[5].sql.contains("EXTRACT(YEAR_MONTH FROM d)"))
        XCTAssertTrue(test.steps[6].sql.contains("ABS(-3),1+1,1"))
        XCTAssertTrue(test.steps[6].sql.contains("20 DIV 5"))
        XCTAssertTrue(test.steps[10].sql.contains("DATE '2026-01-01',ABS(-10)"))
        try check(
            final, "evaluated-date-bounds",
            "SELECT GROUP_CONCAT(PARTITION_DESCRIPTION ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pe_reorganized'",
            "739982,740347,MAXVALUE")
        try check(final, "truncated-date-rows", "SELECT id FROM ddlcompat.pe_truncated ORDER BY id", "2\n3")
        try check(
            final, "computed-list-routing",
            "SELECT GROUP_CONCAT(id ORDER BY id) FROM ddlcompat.pe_list_seed PARTITION(p)", "1,2,3")
        try check(final, "tuple-below-bound", "SELECT id FROM ddlcompat.c PARTITION(p)", "9")
        try check(final, "tuple-at-bound", "SELECT id FROM ddlcompat.c PARTITION(q)", "10")
        try check(final, "final-list-rows", "SELECT id,n FROM ddlcompat.l ORDER BY id", "1\t10\n3\t30\n4\t40\n5\t50")
    }
}
