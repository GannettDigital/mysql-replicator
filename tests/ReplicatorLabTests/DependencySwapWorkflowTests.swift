import XCTest

@testable import ReplicatorLabCore

final class DependencySwapWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int,
        retained: [(Int, String, Int, String)], restarts: [Int], batchSizes: [Int]
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
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + retained.map { "ddlcompat." + $0.3 }.joined(separator: ",")])
        XCTAssertTrue(final.replayResetSQL.contains(final.cleanup[0] + "; DROP DATABASE ddlcompat"))
        var offset = originalCount
        for (start, originalTable, length, table) in retained {
            XCTAssertEqual(
                test.steps[offset..<offset + length].map(\.sql),
                test.steps[start..<start + length].map {
                    $0.sql.replacingOccurrences(of: "ddlcompat." + originalTable, with: "ddlcompat." + table)
                })
            XCTAssertTrue(test.steps[offset..<offset + length].allSatisfy { !$0.restartBefore })
            offset += length
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

    func testGeneratedDependenciesRetainsResultsAndRestartBoundaries() throws {
        let test = DDLCompatibilityCases.generatedDependencies
        let final = try verify(
            test, originalCount: 23,
            retained: [
                (0, "t", 2, "gd_seed"),
                (0, "t", 3, "gd_replaced"),
                (0, "t", 4, "gd_replaced_write"),
                (0, "t", 5, "gd_reverse_order"),
                (0, "t", 6, "gd_renamed"),
                (0, "t", 7, "gd_renamed_write"),
                (0, "t", 8, "gd_dropped"),
                (0, "t", 9, "gd_ordinary"),
                (0, "t", 11, "gd_generated"),
                (0, "t", 12, "gd_final"),
                (12, "q", 2, "gd_q_seed"),
                (12, "q", 3, "gd_q_dropped"),
                (12, "q", 4, "gd_q_recreated"),
                (12, "q", 6, "gd_q_final"),
                (18, "l", 2, "gd_literal_seed"),
                (18, "l", 3, "gd_literal_renamed"),
                (18, "l", 4, "gd_literal_empty"),
            ], restarts: [3, 6, 9, 11], batchSizes: [3, 3, 3, 2, 103])
        XCTAssertEqual(test.steps[3].sql, "UPDATE ddlcompat.t SET b=6 WHERE id=1")
        XCTAssertEqual(test.steps[22].sql, "DROP TABLE ddlcompat.t,ddlcompat.q,ddlcompat.l")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(checks["gd-replaced-values"]?.sql, "SELECT b,g,h,literal_text FROM ddlcompat.gd_replaced")
        XCTAssertEqual(checks["gd-replaced-values"]?.expected, "5\t7\t14\t`a`")
        XCTAssertEqual(checks["gd-replaced-write-values"]?.sql, "SELECT g,h FROM ddlcompat.gd_replaced_write")
        XCTAssertEqual(checks["gd-replaced-write-values"]?.expected, "8\t16")
        XCTAssertEqual(checks["gd-reverse-order-values"]?.sql, "SELECT c,g,h FROM ddlcompat.gd_reverse_order")
        XCTAssertEqual(checks["gd-reverse-order-values"]?.expected, "6\t9\t18")
        XCTAssertEqual(checks["gd-renamed-write-values"]?.sql, "SELECT new_g,h FROM ddlcompat.gd_renamed_write")
        XCTAssertEqual(checks["gd-renamed-write-values"]?.expected, "10\t30")
        XCTAssertEqual(checks["gd-dropped-values"]?.sql, "SELECT d,new_g FROM ddlcompat.gd_dropped")
        XCTAssertEqual(checks["gd-dropped-values"]?.expected, "7\t11")
        XCTAssertEqual(checks["gd-ordinary-values"]?.sql, "SELECT new_g FROM ddlcompat.gd_ordinary")
        XCTAssertEqual(checks["gd-ordinary-values"]?.expected, "11")
        XCTAssertEqual(checks["gd-generated-values"]?.sql, "SELECT d,new_g FROM ddlcompat.gd_generated")
        XCTAssertEqual(checks["gd-generated-values"]?.expected, "4\t12")
        XCTAssertEqual(checks["gd-final-values"]?.sql, "SELECT d,new_g FROM ddlcompat.gd_final")
        XCTAssertEqual(checks["gd-final-values"]?.expected, "5\t12")
        XCTAssertEqual(checks["gd-q-dropped-values"]?.sql, "SELECT id,b FROM ddlcompat.gd_q_dropped")
        XCTAssertEqual(checks["gd-q-dropped-values"]?.expected, "1\t8")
        XCTAssertEqual(checks["gd-literal-renamed-values"]?.sql, "SELECT b,g FROM ddlcompat.gd_literal_renamed")
        XCTAssertEqual(checks["gd-literal-renamed-values"]?.expected, "10\t`a`")
        XCTAssertEqual(checks["seed-values"]?.sql, "SELECT a,g,h,literal_text FROM ddlcompat.gd_seed")
        XCTAssertEqual(checks["seed-values"]?.expected, "5\t6\t12\t`a`")
        XCTAssertEqual(checks["renamed-before-update"]?.sql, "SELECT new_g,h FROM ddlcompat.gd_renamed")
        XCTAssertEqual(checks["renamed-before-update"]?.expected, "9\t27")
        XCTAssertEqual(checks["independent-seed"]?.sql, "SELECT id,a,g FROM ddlcompat.gd_q_seed")
        XCTAssertEqual(checks["independent-seed"]?.expected, "1\t8\t9")
        XCTAssertEqual(checks["recreated-expression"]?.sql, "SELECT id,b,g FROM ddlcompat.gd_q_recreated")
        XCTAssertEqual(checks["recreated-expression"]?.expected, "1\t8\t16")
        XCTAssertEqual(checks["dropped-expression-update"]?.sql, "SELECT id,c FROM ddlcompat.gd_q_final")
        XCTAssertEqual(checks["dropped-expression-update"]?.expected, "1\t9")
        XCTAssertEqual(checks["literal-seed"]?.sql, "SELECT a,g FROM ddlcompat.gd_literal_seed")
        XCTAssertEqual(checks["literal-seed"]?.expected, "10\t`a`")
        XCTAssertEqual(checks["literal-delete"]?.sql, "SELECT COUNT(*) FROM ddlcompat.gd_literal_empty")
        XCTAssertEqual(checks["literal-delete"]?.expected, "0")
        XCTAssertEqual(
            checks["initial-storage-forms"]?.sql,
            "SELECT COLUMN_NAME,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_seed' AND COLUMN_NAME IN ('g','h','literal_text') ORDER BY ORDINAL_POSITION"
        )
        XCTAssertEqual(
            checks["initial-storage-forms"]?.expected,
            "g\tSTORED GENERATED\nh\tVIRTUAL GENERATED\nliteral_text\tSTORED GENERATED")
        XCTAssertEqual(
            checks["ordinary-column"]?.sql,
            "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_ordinary' AND COLUMN_NAME='new_g' AND EXTRA='' AND GENERATION_EXPRESSION=''"
        )
        XCTAssertEqual(checks["ordinary-column"]?.expected, "1")
        XCTAssertEqual(
            checks["converted-storage-form"]?.sql,
            "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_generated' AND COLUMN_NAME='d'"
        )
        XCTAssertEqual(checks["converted-storage-form"]?.expected, "STORED GENERATED")
        XCTAssertEqual(
            checks["renamed-index"]?.sql,
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_dropped' AND INDEX_NAME='by_g' ORDER BY SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["renamed-index"]?.expected, "new_g")
        XCTAssertEqual(
            checks["original-tables-dropped"]?.sql,
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','q','l')"
        )
        XCTAssertEqual(checks["original-tables-dropped"]?.expected, "0")
        XCTAssertEqual(final.checks.count, 22)
    }

    func testColumnSwapsRetainsResultsAndRestartBoundaries() throws {
        let test = DDLCompatibilityCases.columnSwaps
        let final = try verify(
            test, originalCount: 15,
            retained: [
                (0, "t", 2, "cs_seed"),
                (0, "t", 3, "cs_swapped"),
                (0, "t", 4, "cs_written"),
                (0, "t", 5, "cs_positioned"),
                (0, "t", 6, "cs_chain"),
                (0, "t", 7, "cs_added"),
                (0, "t", 8, "cs_added_write"),
                (0, "t", 9, "cs_reused"),
                (0, "t", 10, "cs_deleted"),
                (10, "g", 2, "cs_g_seed"),
                (10, "g", 3, "cs_g_swapped"),
                (10, "g", 4, "cs_g_updated"),
            ], restarts: [3, 5, 7, 12], batchSizes: [3, 2, 2, 5, 66])
        XCTAssertEqual(test.steps[2].sql, "ALTER TABLE ddlcompat.t CHANGE a b INT,CHANGE b a INT")
        XCTAssertEqual(test.steps[14].sql, "DROP TABLE ddlcompat.g,ddlcompat.t")
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check) })
        XCTAssertEqual(checks["cs-swapped-values"]?.sql, "SELECT * FROM ddlcompat.cs_swapped ORDER BY b")
        XCTAssertEqual(checks["cs-swapped-values"]?.expected, "1\t10\t100\n2\t20\t200")
        XCTAssertEqual(
            checks["cs-swapped-keys"]?.sql,
            "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_swapped' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["cs-swapped-keys"]?.expected, "PRIMARY\tb\nPRIMARY\ta\nka\tb\nkb\ta")
        XCTAssertEqual(checks["cs-written-values"]?.sql, "SELECT b,a,c FROM ddlcompat.cs_written WHERE b=1")
        XCTAssertEqual(checks["cs-written-values"]?.expected, "1\t11\t101")
        XCTAssertEqual(checks["cs-positioned-values"]?.sql, "SELECT * FROM ddlcompat.cs_positioned ORDER BY a")
        XCTAssertEqual(checks["cs-positioned-values"]?.expected, "11\t101\t1\n20\t200\t2")
        XCTAssertEqual(checks["cs-chain-values"]?.sql, "SELECT * FROM ddlcompat.cs_chain ORDER BY b")
        XCTAssertEqual(checks["cs-chain-values"]?.expected, "11\t101\t1\n20\t200\t2")
        XCTAssertEqual(checks["cs-added-values"]?.sql, "SELECT * FROM ddlcompat.cs_added ORDER BY c")
        XCTAssertEqual(checks["cs-added-values"]?.expected, "11\t7\t101\t1\n20\t7\t200\t2")
        XCTAssertEqual(checks["cs-added-write-values"]?.sql, "SELECT b,n,d,c FROM ddlcompat.cs_added_write ORDER BY c")
        XCTAssertEqual(checks["cs-added-write-values"]?.expected, "12\t7\t102\t1\n20\t7\t200\t2")
        XCTAssertEqual(checks["cs-reused-values"]?.sql, "SELECT * FROM ddlcompat.cs_reused ORDER BY c")
        XCTAssertEqual(checks["cs-reused-values"]?.expected, "7\t102\t1\n7\t200\t2")
        XCTAssertEqual(checks["cs-deleted-values"]?.sql, "SELECT * FROM ddlcompat.cs_deleted")
        XCTAssertEqual(checks["cs-deleted-values"]?.expected, "7\t102\t1")
        XCTAssertEqual(checks["cs-g-swapped-values"]?.sql, "SELECT id,b,a,g FROM ddlcompat.cs_g_swapped")
        XCTAssertEqual(checks["cs-g-swapped-values"]?.expected, "1\t10\t20\t11")
        XCTAssertEqual(checks["cs-g-updated-values"]?.sql, "SELECT id,b,a,g FROM ddlcompat.cs_g_updated")
        XCTAssertEqual(checks["cs-g-updated-values"]?.expected, "1\t12\t20\t13")
        XCTAssertEqual(checks["seed-values"]?.sql, "SELECT * FROM ddlcompat.cs_seed ORDER BY a")
        XCTAssertEqual(checks["seed-values"]?.expected, "1\t10\t100\n2\t20\t200")
        XCTAssertEqual(checks["generated-seed"]?.sql, "SELECT id,a,b,g FROM ddlcompat.cs_g_seed")
        XCTAssertEqual(checks["generated-seed"]?.expected, "1\t10\t20\t11")
        XCTAssertEqual(
            checks["keys-after-column-drop"]?.sql,
            "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_reused' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX"
        )
        XCTAssertEqual(checks["keys-after-column-drop"]?.expected, "PRIMARY\tc\nka\tc")
        XCTAssertEqual(
            checks["original-tables-dropped"]?.sql,
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','g')")
        XCTAssertEqual(checks["original-tables-dropped"]?.expected, "0")
        XCTAssertEqual(final.checks.count, 15)
    }

    func testForeignKeySwapExecutionIsUnchanged() throws {
        XCTAssertNil(try DDLExecutionPhase.plan(DDLCompatibilityCases.foreignKeyColumnSwaps.steps))
        XCTAssertNil(DDLCompatibilityCases.foreignKeyColumnSwaps.finalObservations)
    }
}
