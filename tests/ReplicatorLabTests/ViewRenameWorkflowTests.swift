import XCTest

@testable import ReplicatorLabCore

final class ViewRenameWorkflowTests: XCTestCase {
    func testHistoriesPreserveCompleteRenameChainsAndTemporaryAliases() throws {
        let test = DDLCompatibilityCases.viewRenames
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 77)
        XCTAssertEqual(phases.map { $0.steps.count }, [6, 2, 4, 65])
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [7, 9, 13])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil })
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        XCTAssertEqual(final.databases, ["ddlcompat", "view_rename_results"])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE view_rename_results"])
        XCTAssertEqual(
            test.steps[13].sql, "CREATE DATABASE view_rename_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        let stems = ["vr_seed", "vr_renamed", "vr_swapped", "vr_mixed", "vr_updated", "vr_inserted", "vr_final_names"]
        let names = ["final_view", "renamed", "moved", "aux", "tmp", "v2", "t", "v"]
        var offset = 14
        for (index, stem) in stems.enumerated() {
            let length = index + 6
            let expected = test.steps.prefix(length).map { step in
                names.reduce(step.sql) { sql, name in
                    sql.replacingOccurrences(of: "ddlcompat." + name, with: "view_rename_results." + stem + "_" + name)
                }
            }
            let actual = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(actual.map(\.sql), expected)
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore && !$0.sql.contains("ddlcompat.") })
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
    }

    func testOriginalRenameStatementsAndScopedJournalRemainExact() {
        let steps = DDLCompatibilityCases.viewRenames.steps
        let expected = [
            "RENAME TABLE ddlcompat.v TO ddlcompat.renamed",
            "RENAME TABLE ddlcompat.renamed TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.renamed,ddlcompat.tmp TO ddlcompat.v2",
            "RENAME TABLE ddlcompat.aux TO ddlcompat.tmp,ddlcompat.v2 TO ddlcompat.aux,ddlcompat.tmp TO ddlcompat.v2",
            "RENAME TABLE ddlcompat.v2 TO ddlcompat.moved,ddlcompat.aux TO ddlcompat.final_view",
        ]
        XCTAssertEqual(steps.prefix(13).filter { $0.sql.hasPrefix("RENAME TABLE ") }.map(\.sql), expected)
        XCTAssertEqual(steps[12].sql, "DELETE FROM ddlcompat.moved WHERE id=2")
        let query = ViewRenameWorkflowEvidence.originalJournalSQL
        XCTAssertTrue(query.contains("status='DONE'"))
        XCTAssertTrue(query.contains("json_array_length(context_json,'$.viewTransitions')>0"))
        XCTAssertTrue(query.contains("source_sql IN ("))
        for sql in expected { XCTAssertTrue(query.contains("'" + sql + "'")) }
        XCTAssertFalse(query.contains("view_rename_results"))
    }

    func testCacheIdentitiesFollowObjectTypesRatherThanNameSuffixes() {
        let views = ViewRenameWorkflowEvidence.retainedViews
        let bases = ViewRenameWorkflowEvidence.retainedBaseTables
        XCTAssertEqual(Set(views).count, 14)
        XCTAssertEqual(Set(bases).count, 14)
        XCTAssertTrue(Set(views).isDisjoint(with: bases))
        XCTAssertTrue(views.contains("vr_swapped_v2"))
        XCTAssertFalse(bases.contains("vr_swapped_v2"))
        XCTAssertTrue(bases.contains("vr_mixed_v2"))
        XCTAssertTrue(views.contains("vr_mixed_aux"))
        XCTAssertTrue(bases.contains("vr_final_names_moved"))
        XCTAssertTrue(views.contains("vr_final_names_final_view"))
        XCTAssertFalse((views + bases).contains { $0.hasSuffix("_tmp") })
        for names in [views, bases] {
            let sql = ViewRenameWorkflowEvidence.cacheSQL(names)
            XCTAssertTrue(sql.contains("current=1"))
            XCTAssertTrue(sql.contains("'view_rename_results'"))
            for name in names { XCTAssertTrue(sql.contains("'" + name + "'")) }
        }
    }

    func testJournalAndCacheQueriesUseSQLiteStringLiterals() {
        XCTAssertEqual(ViewRenameWorkflowEvidence.sqliteLiteral("O'Reilly"), "'O''Reilly'")
        XCTAssertEqual(ViewRenameWorkflowEvidence.sqliteLiteral("view_name"), "'view_name'")
        for query in [
            ViewRenameWorkflowEvidence.originalJournalSQL,
            ViewRenameWorkflowEvidence.cacheSQL(["O'Reilly"]),
        ] {
            XCTAssertFalse(query.contains("CONVERT("))
            XCTAssertFalse(query.contains("USING utf8mb4"))
        }
        XCTAssertTrue(ViewRenameWorkflowEvidence.cacheSQL(["O'Reilly"]).contains("IN ('O''Reilly')"))
    }

    func testAllOriginalPredicatesRemainWithReadOnlyFinalChecks() throws {
        let final = try XCTUnwrap(DDLCompatibilityCases.viewRenames.finalObservations)
        let expected: [(String, String, String)] = [
            ("single-rename-rows", "SELECT * FROM view_rename_results.vr_renamed_renamed", "1\t10"),
            (
                "single-rename-metadata",
                "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME='vr_renamed_renamed'",
                "root@localhost\tINVOKER\tLOCAL"
            ),
            ("swapped-definer-view-rows", "SELECT * FROM view_rename_results.vr_swapped_renamed", "1\t11"),
            ("swapped-invoker-view-rows", "SELECT * FROM view_rename_results.vr_swapped_v2", "1\t10"),
            ("mixed-view-rows", "SELECT * FROM view_rename_results.vr_mixed_aux", "1\t10"),
            ("mixed-base-rows", "SELECT * FROM view_rename_results.vr_mixed_v2", "2\t20"),
            ("updated-base-rows", "SELECT * FROM view_rename_results.vr_updated_v2", "2\t21"),
            ("insert-through-view-rows", "SELECT * FROM view_rename_results.vr_inserted_t ORDER BY id", "1\t10\n3\t30"),
            (
                "final-view-rows", "SELECT * FROM view_rename_results.vr_final_names_final_view ORDER BY id",
                "1\t10\n3\t30"
            ),
            (
                "final-view-metadata",
                "SELECT DEFINER,SECURITY_TYPE,CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='view_rename_results' AND TABLE_NAME='vr_final_names_final_view'",
                "root@localhost\tINVOKER\tLOCAL"
            ),
            ("deleted-moved-table-empty", "SELECT COUNT(*) FROM ddlcompat.moved", "0"),
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
        XCTAssertEqual(final.checks.count, 19)
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
    }
}
