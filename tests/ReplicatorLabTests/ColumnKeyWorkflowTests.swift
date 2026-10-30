import XCTest

@testable import ReplicatorLabCore

final class ColumnKeyWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int,
        retained: [([Int], String, String)], restarts: [Int], batchSizes: [Int]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, batchSizes)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }, restarts)
        XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
        XCTAssertTrue(phases.allSatisfy { $0.checks.isEmpty })
        XCTAssertTrue(
            test.steps.allSatisfy {
                $0.sql == $0.sqlTransactional && $0.transactions == 1 && $0.assertionID == nil
            })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + retained.map { "ddlcompat." + $0.2 }.joined(separator: ",")])
        XCTAssertTrue(final.replayResetSQL.contains(final.cleanup[0] + "; DROP DATABASE ddlcompat"))
        var offset = originalCount
        for (indices, originalTable, table) in retained {
            XCTAssertEqual(
                test.steps[offset..<offset + indices.count].map(\.sql),
                indices.map {
                    test.steps[$0].sql.replacingOccurrences(
                        of: "ddlcompat." + originalTable, with: "ddlcompat." + table)
                })
            XCTAssertTrue(test.steps[offset..<offset + indices.count].allSatisfy { !$0.restartBefore })
            offset += indices.count
        }
        XCTAssertEqual(offset, test.steps.count)
        for check in final.checks {
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([check.id: check.check.expected], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([check.id: "wrong"], engine: engine, role: "target"))
            }
        }
        return final
    }

    func testColumnIndexSyntaxRetainsResultsAndRestartBoundaries() throws {
        let test = DDLCompatibilityCases.columnIndexSyntax
        let final = try verify(
            test, originalCount: 20,
            retained: [
                ([0, 1], "t", "ci_inline"),
                ([0, 1, 2, 3, 4], "t", "ci_grouped"),
                ([0, 1, 2, 3, 4, 5, 6], "t", "ci_index_created"),
                ([0, 1, 2, 3, 4, 5, 6, 7, 8], "t", "ci_index_dropped"),
                ([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "t", "ci_final"),
                ([11, 12], "s", "ci_serial_seed"),
                ([11, 12, 13], "s", "ci_serial_updated"),
                ([11, 12, 13, 18], "s", "ci_serial_deleted"),
                ([14, 15, 16, 17], "q", "ci_serial_default"),
            ], restarts: [5, 13], batchSizes: [5, 8, 54])
        XCTAssertEqual(test.steps[3].sql, "UPDATE ddlcompat.t SET c=4,d=5,e=6 WHERE id=1")
        XCTAssertEqual(test.steps[19].sql, "DROP TABLE ddlcompat.t,ddlcompat.s,ddlcompat.q")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(
            checks["ci-grouped-metadata"]?.sql,
            "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_grouped' AND COLUMN_NAME='a' ORDER BY INDEX_NAME"
        )
        XCTAssertEqual(checks["ci-grouped-metadata"]?.expected, "a\na_2")
        XCTAssertEqual(checks["ci-final-values"]?.sql, "SELECT id,a,renamed,c FROM ddlcompat.ci_final ORDER BY id")
        XCTAssertEqual(checks["ci-final-values"]?.expected, "1\t12\t22\t8\n2\t11\t21\t3")
        XCTAssertEqual(checks["inline-seed-rows"]?.sql, "SELECT * FROM ddlcompat.ci_inline ORDER BY id")
        XCTAssertEqual(checks["inline-seed-rows"]?.expected, "1\t10\t20\tfirst\n2\t11\t21\tsecond")
        XCTAssertEqual(checks["grouped-defaults"]?.sql, "SELECT id,c,d,e FROM ddlcompat.ci_grouped ORDER BY id")
        XCTAssertEqual(checks["grouped-defaults"]?.expected, "1\t4\t5\t6\n2\t3\tNULL\tNULL")
        XCTAssertEqual(
            checks["created-index"]?.sql,
            "SELECT COLUMN_NAME,NON_UNIQUE,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_index_created' AND INDEX_NAME='by_d' ORDER BY SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["created-index"]?.expected, "d\t1\tBTREE")
        XCTAssertEqual(
            checks["dropped-index"]?.sql,
            "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_index_dropped' AND INDEX_NAME='by_d'"
        )
        XCTAssertEqual(checks["dropped-index"]?.expected, "0")
        XCTAssertEqual(checks["serial-seed"]?.sql, "SELECT id,v FROM ddlcompat.ci_serial_seed ORDER BY id")
        XCTAssertEqual(checks["serial-seed"]?.expected, "1\t40\n2\t41")
        XCTAssertEqual(checks["serial-update"]?.sql, "SELECT id,v FROM ddlcompat.ci_serial_updated ORDER BY id")
        XCTAssertEqual(checks["serial-update"]?.expected, "1\t42\n2\t41")
        XCTAssertEqual(checks["serial-delete"]?.sql, "SELECT id,v FROM ddlcompat.ci_serial_deleted ORDER BY id")
        XCTAssertEqual(checks["serial-delete"]?.expected, "1\t42")
        XCTAssertEqual(
            checks["serial-default-values"]?.sql, "SELECT id,v,extra FROM ddlcompat.ci_serial_default ORDER BY id")
        XCTAssertEqual(checks["serial-default-values"]?.expected, "1\t50\t60\n2\t51\tNULL")
        XCTAssertEqual(
            checks["serial-default-unique-key"]?.sql,
            "SELECT COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_serial_default' AND INDEX_NAME='extra' ORDER BY SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["serial-default-unique-key"]?.expected, "extra\t0")
        XCTAssertEqual(
            checks["original-tables-dropped"]?.sql,
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','s','q')"
        )
        XCTAssertEqual(checks["original-tables-dropped"]?.expected, "0")
        XCTAssertEqual(final.checks.count, 12)
    }

    func testAlterColumnKeysRetainsResultsAndRestartBoundaries() throws {
        let test = DDLCompatibilityCases.alterColumnKeys
        let final = try verify(
            test, originalCount: 25,
            retained: [
                ([0, 1, 2], "t", "ak_implicit_key"),
                ([0, 1, 2, 3, 4], "t", "ak_implicit_defaults"),
                ([0, 1, 2, 3, 4, 5], "t", "ak_modified_key"),
                ([0, 1, 2, 3, 4, 5, 6], "t", "ak_renamed_key"),
                ([0, 1, 2, 3, 4, 5, 6, 7], "t", "ak_renamed_write"),
                ([0, 1, 2, 3, 4, 5, 6, 7, 8], "t", "ak_rebuilt"),
                ([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], "t", "ak_inserted"),
                ([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], "t", "ak_deleted"),
                ([12, 13, 14], "e", "ak_empty"),
                ([15, 16, 17], "u", "ak_secondary"),
                ([15, 16, 17, 18], "u", "ak_promoted"),
                ([15, 16, 17, 18, 19, 20], "u", "ak_promoted_write"),
                ([21, 22, 23], "c", "ak_grouped"),
            ], restarts: [7, 10, 19], batchSizes: [7, 3, 9, 85])
        XCTAssertEqual(test.steps[3].sql, "UPDATE ddlcompat.t SET id=1,v=8 WHERE id=0")
        XCTAssertEqual(test.steps[24].sql, "DROP TABLE ddlcompat.t,ddlcompat.e,ddlcompat.u,ddlcompat.c")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(checks["ak-implicit-key-values"]?.sql, "SELECT id,v FROM ddlcompat.ak_implicit_key")
        XCTAssertEqual(checks["ak-implicit-key-values"]?.expected, "0\t7")
        XCTAssertEqual(
            checks["ak-implicit-defaults-values"]?.sql,
            "SELECT id,v,n,CONCAT('[',s,']') FROM ddlcompat.ak_implicit_defaults")
        XCTAssertEqual(checks["ak-implicit-defaults-values"]?.expected, "1\t8\t0\t[]")
        XCTAssertEqual(
            checks["ak-implicit-defaults-metadata"]?.sql,
            "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_implicit_defaults' AND COLUMN_NAME IN('n','s') AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL"
        )
        XCTAssertEqual(checks["ak-implicit-defaults-metadata"]?.expected, "2")
        XCTAssertEqual(checks["ak-renamed-write-values"]?.sql, "SELECT k,v,n,s FROM ddlcompat.ak_renamed_write")
        XCTAssertEqual(checks["ak-renamed-write-values"]?.expected, "2\t8\t9\tx")
        XCTAssertEqual(checks["ak-rebuilt-values"]?.sql, "SELECT aid,k,v FROM ddlcompat.ak_rebuilt")
        XCTAssertEqual(checks["ak-rebuilt-values"]?.expected, "2\t2\t8")
        XCTAssertEqual(checks["ak-inserted-values"]?.sql, "SELECT aid,k FROM ddlcompat.ak_inserted ORDER BY aid")
        XCTAssertEqual(checks["ak-inserted-values"]?.expected, "2\t2\n5\t3")
        XCTAssertEqual(checks["ak-empty-values"]?.sql, "SELECT id,v FROM ddlcompat.ak_empty ORDER BY id")
        XCTAssertEqual(checks["ak-empty-values"]?.expected, "1\t20\n2\t30")
        XCTAssertEqual(checks["ak-secondary-values"]?.sql, "SELECT id,seq FROM ddlcompat.ak_secondary ORDER BY id")
        XCTAssertEqual(checks["ak-secondary-values"]?.expected, "1\t1\n2\t2")
        XCTAssertEqual(checks["ak-grouped-values"]?.sql, "SELECT id,v FROM ddlcompat.ak_grouped")
        XCTAssertEqual(checks["ak-grouped-values"]?.expected, "1\t40")
        XCTAssertEqual(
            checks["modified-key"]?.sql,
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_modified_key' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["modified-key"]?.expected, "id")
        XCTAssertEqual(
            checks["renamed-column-order"]?.sql,
            "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_renamed_key' ORDER BY ORDINAL_POSITION"
        )
        XCTAssertEqual(checks["renamed-column-order"]?.expected, "v\nk\nn\ns")
        XCTAssertEqual(
            checks["renamed-primary-key"]?.sql,
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_renamed_key' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["renamed-primary-key"]?.expected, "k")
        XCTAssertEqual(checks["auto-increment-update-delete"]?.sql, "SELECT aid,k,v,n,s FROM ddlcompat.ak_deleted")
        XCTAssertEqual(checks["auto-increment-update-delete"]?.expected, "5\t3\t12\t11\ty")
        XCTAssertEqual(
            checks["secondary-auto-increment-key"]?.sql,
            "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_secondary' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["secondary-auto-increment-key"]?.expected, "PRIMARY\tid\nby_seq\tseq")
        XCTAssertEqual(
            checks["promoted-primary-key"]?.sql,
            "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_promoted' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["promoted-primary-key"]?.expected, "PRIMARY\tseq")
        XCTAssertEqual(checks["promoted-rows"]?.sql, "SELECT id,v,seq FROM ddlcompat.ak_promoted ORDER BY id")
        XCTAssertEqual(checks["promoted-rows"]?.expected, "1\t10\t1\n2\t20\t2")
        XCTAssertEqual(checks["promoted-key-update-delete"]?.sql, "SELECT id,v,seq FROM ddlcompat.ak_promoted_write")
        XCTAssertEqual(checks["promoted-key-update-delete"]?.expected, "2\t21\t2")
        XCTAssertEqual(
            checks["original-tables-dropped"]?.sql,
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','e','u','c')"
        )
        XCTAssertEqual(checks["original-tables-dropped"]?.expected, "0")
        XCTAssertEqual(final.checks.count, 18)
    }

    func testAutoIncrementOverridesDoNotLeakBetweenRetainedSequences() throws {
        let test = DDLCompatibilityCases.alterColumnKeys
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        for transactional in [false, true] {
            let writes = phases.flatMap { $0.writes(transactional: transactional) }
            let reset =
                "SET SESSION auto_increment_increment=@@GLOBAL.auto_increment_increment,auto_increment_offset=@@GLOBAL.auto_increment_offset; SET SESSION timestamp=DEFAULT; "
            XCTAssertTrue(writes.allSatisfy { $0.sql.hasPrefix(reset) })
            let overrides = writes.indices.filter {
                writes[$0].sql.contains("SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER")
            }
            // The original rebuild and three retained prefixes must carry the same context.
            XCTAssertEqual(overrides.count, 4)
            XCTAssertEqual(overrides.first, 8)
            for index in overrides {
                XCTAssertTrue(writes[index + 1].sql.hasPrefix(reset))
                XCTAssertFalse(writes[index + 1].sql.contains("auto_increment_increment=3"))
            }
            XCTAssertTrue(writes[9].sql.hasSuffix("INSERT INTO ddlcompat.t(k,v,n,s) VALUES(3,10,11,'y')"))
        }
        let originalRebuilds = test.steps.filter { $0.sql.contains("ALTER TABLE ddlcompat.t ADD aid") }
        XCTAssertEqual(originalRebuilds.count, 1)
    }
}
