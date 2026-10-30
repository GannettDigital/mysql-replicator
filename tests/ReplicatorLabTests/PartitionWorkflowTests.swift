import XCTest

@testable import ReplicatorLabCore

final class PartitionWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int,
        retained: [(Int, [(String, String)])], total: Int
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(test.steps.count, total)
        XCTAssertTrue(test.nativeInnoDB)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(
            test.steps.allSatisfy {
                !$0.restartBefore && $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil
            })
        XCTAssertEqual(phases[0].steps.map(\.sql), test.steps.map(\.sql))
        XCTAssertTrue(phases[0].checks.isEmpty)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        var offset = originalCount
        for (length, replacements) in retained {
            let expected = test.steps.prefix(length).map { step in
                replacements.reduce(step.sql) { sql, names in
                    sql.replacingOccurrences(of: "ddlcompat." + names.0, with: "ddlcompat." + names.1)
                }
            }
            XCTAssertEqual(test.steps[offset..<offset + length].map(\.sql), expected)
            offset += length
        }
        XCTAssertEqual(offset, total)
        XCTAssertEqual(
            final.cleanup,
            ["DROP TABLE " + retained.flatMap { $0.1.map { "ddlcompat." + $0.1 } }.joined(separator: ",")])
        XCTAssertFalse(final.cleanup[0].contains("ddlcompat.t,"))
        XCTAssertFalse(final.cleanup[0].contains("ddlcompat.stage"))
        for check in final.checks {
            for engine in ["MyISAM", "InnoDB"] {
                _ = try check.result([check.id: check.check.expected], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([check.id: "wrong"], engine: engine, role: "target"))
            }
        }
        return final
    }

    func testRangePartitionManagementPreservesStatesAndNativeEngine() throws {
        let test = DDLCompatibilityCases.rangePartitionManagement
        let final = try verify(
            test, originalCount: 10,
            retained: [
                (2, [("t", "pr_seed")]),
                (3, [("t", "pr_dropped")]),
                (4, [("t", "pr_truncated")]),
                (5, [("t", "pr_reorganized")]),
                (6, [("t", "pr_stage_empty"), ("stage", "pr_stage_empty_stage")]),
                (7, [("t", "pr_stage_seeded"), ("stage", "pr_stage_seeded_stage")]),
                (8, [("t", "pr_exchanged"), ("stage", "pr_exchanged_stage")]),
                (9, [("t", "pr_updated"), ("stage", "pr_updated_stage")]),
            ], total: 54)
        XCTAssertEqual(
            test.steps[7].sql,
            "ALTER TABLE ddlcompat.t EXCHANGE PARTITION next_year WITH TABLE ddlcompat.stage WITH VALIDATION")
        XCTAssertEqual(test.steps[9].sql, "ALTER TABLE ddlcompat.t REMOVE PARTITIONING")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(checks["drop-removes-old-row"]?.sql, "SELECT id FROM ddlcompat.pr_dropped ORDER BY id")
        XCTAssertEqual(checks["drop-removes-old-row"]?.expected, "2\n3")
        XCTAssertEqual(checks["truncate-removes-current-row"]?.sql, "SELECT id FROM ddlcompat.pr_truncated ORDER BY id")
        XCTAssertEqual(checks["truncate-removes-current-row"]?.expected, "3")
        XCTAssertEqual(checks["exchange-partition-rows"]?.sql, "SELECT id FROM ddlcompat.pr_exchanged ORDER BY id")
        XCTAssertEqual(checks["exchange-partition-rows"]?.expected, "4")
        XCTAssertEqual(checks["exchange-table-rows"]?.sql, "SELECT id FROM ddlcompat.pr_exchanged_stage ORDER BY id")
        XCTAssertEqual(checks["exchange-table-rows"]?.expected, "3")
        XCTAssertEqual(checks["update-after-exchange"]?.sql, "SELECT n FROM ddlcompat.pr_updated")
        XCTAssertEqual(checks["update-after-exchange"]?.expected, "41")
        XCTAssertEqual(
            checks["remove-partitioning"]?.sql,
            "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND PARTITION_NAME IS NOT NULL"
        )
        XCTAssertEqual(checks["remove-partitioning"]?.expected, "0")
        XCTAssertEqual(checks["seed-rows"]?.sql, "SELECT id,n FROM ddlcompat.pr_seed ORDER BY id")
        XCTAssertEqual(checks["seed-rows"]?.expected, "1\t10\n2\t20\n3\t30")
        XCTAssertEqual(
            checks["truncated-partition-empty"]?.sql,
            "SELECT COUNT(*) FROM ddlcompat.pr_truncated PARTITION(current_data)")
        XCTAssertEqual(checks["truncated-partition-empty"]?.expected, "0")
        XCTAssertEqual(
            checks["reorganized-row-placement"]?.sql, "SELECT id,n FROM ddlcompat.pr_reorganized PARTITION(next_year)")
        XCTAssertEqual(checks["reorganized-row-placement"]?.expected, "3\t30")
        XCTAssertEqual(
            checks["exchange-table-initially-empty"]?.sql, "SELECT COUNT(*) FROM ddlcompat.pr_stage_empty_stage")
        XCTAssertEqual(checks["exchange-table-initially-empty"]?.expected, "0")
        XCTAssertEqual(
            checks["exchange-table-before-exchange"]?.sql, "SELECT id,n FROM ddlcompat.pr_stage_seeded_stage")
        XCTAssertEqual(checks["exchange-table-before-exchange"]?.expected, "4\t40")
        XCTAssertEqual(
            checks["partition-before-exchange"]?.sql, "SELECT id,n FROM ddlcompat.pr_stage_seeded PARTITION(next_year)")
        XCTAssertEqual(checks["partition-before-exchange"]?.expected, "3\t30")
        XCTAssertEqual(
            checks["exchange-before-update"]?.sql, "SELECT id,n FROM ddlcompat.pr_exchanged PARTITION(next_year)")
        XCTAssertEqual(checks["exchange-before-update"]?.expected, "4\t40")
        XCTAssertEqual(checks["exchange-table-after-update"]?.sql, "SELECT id,n FROM ddlcompat.pr_updated_stage")
        XCTAssertEqual(checks["exchange-table-after-update"]?.expected, "3\t30")
        XCTAssertEqual(checks["final-unpartitioned-rows"]?.sql, "SELECT id,n FROM ddlcompat.t")
        XCTAssertEqual(checks["final-unpartitioned-rows"]?.expected, "4\t41")
        XCTAssertEqual(checks["final-exchange-table-rows"]?.sql, "SELECT id,n FROM ddlcompat.stage")
        XCTAssertEqual(checks["final-exchange-table-rows"]?.expected, "3\t30")
        XCTAssertEqual(
            checks["initial-partitions"]?.sql,
            "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_seed'"
        )
        XCTAssertEqual(checks["initial-partitions"]?.expected, "old,current_data,future")
        XCTAssertEqual(
            checks["dropped-partition-absent"]?.sql,
            "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_dropped'"
        )
        XCTAssertEqual(checks["dropped-partition-absent"]?.expected, "current_data,future")
        XCTAssertEqual(
            checks["truncated-partition-retained"]?.sql,
            "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_truncated'"
        )
        XCTAssertEqual(checks["truncated-partition-retained"]?.expected, "current_data,future")
        XCTAssertEqual(
            checks["reorganized-partitions"]?.sql,
            "SELECT GROUP_CONCAT(PARTITION_NAME ORDER BY PARTITION_ORDINAL_POSITION) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pr_reorganized'"
        )
        XCTAssertEqual(checks["reorganized-partitions"]?.expected, "current_data,next_year,future")
        XCTAssertEqual(final.checks.count, 20)
    }

    func testHashKeyListManagementPreservesStatesAndNativeEngine() throws {
        let test = DDLCompatibilityCases.hashKeyListManagement
        let final = try verify(
            test, originalCount: 7,
            retained: [
                (2, [("t", "ph_seed")]),
                (3, [("t", "ph_coalesced")]),
                (4, [("t", "ph_key")]),
                (5, [("t", "ph_list")]),
                (6, [("t", "ph_added")]),
            ], total: 27)
        XCTAssertEqual(test.steps[3].sql, "ALTER TABLE ddlcompat.t PARTITION BY KEY(id) PARTITIONS 2")
        XCTAssertEqual(test.steps[6].sql, "INSERT INTO ddlcompat.t VALUES(3,30)")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(checks["coalesce-retains-values"]?.sql, "SELECT SUM(n) FROM ddlcompat.ph_coalesced")
        XCTAssertEqual(checks["coalesce-retains-values"]?.expected, "30")
        XCTAssertEqual(checks["insert-into-added-partition"]?.sql, "SELECT SUM(n) FROM ddlcompat.t")
        XCTAssertEqual(checks["insert-into-added-partition"]?.expected, "60")
        XCTAssertEqual(checks["seed-rows"]?.sql, "SELECT id,n FROM ddlcompat.ph_seed ORDER BY id")
        XCTAssertEqual(checks["seed-rows"]?.expected, "1\t10\n2\t20")
        XCTAssertEqual(checks["coalesced-rows"]?.sql, "SELECT id,n FROM ddlcompat.ph_coalesced ORDER BY id")
        XCTAssertEqual(checks["coalesced-rows"]?.expected, "1\t10\n2\t20")
        XCTAssertEqual(checks["key-rows"]?.sql, "SELECT id,n FROM ddlcompat.ph_key ORDER BY id")
        XCTAssertEqual(checks["key-rows"]?.expected, "1\t10\n2\t20")
        XCTAssertEqual(checks["list-first-partition"]?.sql, "SELECT id,n FROM ddlcompat.ph_list PARTITION(p1)")
        XCTAssertEqual(checks["list-first-partition"]?.expected, "1\t10")
        XCTAssertEqual(checks["list-second-partition"]?.sql, "SELECT id,n FROM ddlcompat.ph_list PARTITION(p2)")
        XCTAssertEqual(checks["list-second-partition"]?.expected, "2\t20")
        XCTAssertEqual(checks["added-partition-empty"]?.sql, "SELECT COUNT(*) FROM ddlcompat.ph_added PARTITION(p3)")
        XCTAssertEqual(checks["added-partition-empty"]?.expected, "0")
        XCTAssertEqual(checks["added-partition-row"]?.sql, "SELECT id,n FROM ddlcompat.t PARTITION(p3)")
        XCTAssertEqual(checks["added-partition-row"]?.expected, "3\t30")
        XCTAssertEqual(checks["final-rows"]?.sql, "SELECT id,n FROM ddlcompat.t ORDER BY id")
        XCTAssertEqual(checks["final-rows"]?.expected, "1\t10\n2\t20\n3\t30")
        XCTAssertEqual(
            checks["initial-hash-partitions"]?.sql,
            "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_seed' GROUP BY PARTITION_METHOD"
        )
        XCTAssertEqual(checks["initial-hash-partitions"]?.expected, "HASH\t4")
        XCTAssertEqual(
            checks["coalesced-hash-partitions"]?.sql,
            "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_coalesced' GROUP BY PARTITION_METHOD"
        )
        XCTAssertEqual(checks["coalesced-hash-partitions"]?.expected, "HASH\t2")
        XCTAssertEqual(
            checks["key-partitions"]?.sql,
            "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_key' GROUP BY PARTITION_METHOD"
        )
        XCTAssertEqual(checks["key-partitions"]?.expected, "KEY\t2")
        XCTAssertEqual(
            checks["list-partitions"]?.sql,
            "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_list' GROUP BY PARTITION_METHOD"
        )
        XCTAssertEqual(checks["list-partitions"]?.expected, "LIST\t2")
        XCTAssertEqual(
            checks["added-list-partition"]?.sql,
            "SELECT PARTITION_METHOD,COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ph_added' GROUP BY PARTITION_METHOD"
        )
        XCTAssertEqual(checks["added-list-partition"]?.expected, "LIST\t3")
        XCTAssertEqual(final.checks.count, 15)
    }
}
