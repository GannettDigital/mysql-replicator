import XCTest

@testable import ReplicatorLabCore

final class ExecutableCommentWorkflowTests: XCTestCase {
    private var cases: [DDLCompatibilityCases.Case] {
        [
            DDLCompatibilityCases.executableComments, DDLCompatibilityCases.executableCommentsTargetGate,
            DDLCompatibilityCases.executableCommentsSourceGate,
        ]
    }

    func testSourceBatchesPreserveRestartsTransactionsAndExclusions() throws {
        for (test, sizes) in zip(cases, [[2, 3, 8], [1, 3], [1, 3]]) {
            let restarts = test.steps.indices.filter { test.steps[$0].restartBefore }
            // Phase checks also reject a restart hidden inside a source batch.
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
            let final = try XCTUnwrap(test.finalObservations)
            try final.validate(phases)
            XCTAssertEqual(phases.map { $0.steps.count }, sizes)
            XCTAssertEqual(restarts.map { $0 + 1 }, test.test.id == "ddl-compat-executable-comments" ? [3, 6] : [2])
            XCTAssertTrue(
                test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional && $0.assertionID == nil }
            )
            XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
            XCTAssertFalse(test.nativeInnoDB)
            XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        }
        XCTAssertTrue(cases[0].profileExclusions.isEmpty)
        XCTAssertEqual(
            cases[1].profileExclusions,
            [
                .reverse: "Requires an 8.4 source and a 5.7 target.",
                .mysql57MyISAM: "Requires an 8.4 source and a 5.7 target.",
                .mysql57InnoDB: "Requires an 8.4 source and a 5.7 target.",
            ])
        XCTAssertEqual(cases[2].profileExclusions, [.forward: "This case tests a comment disabled by the 5.7 source."])
        for test in cases.suffix(2) {
            let final = try XCTUnwrap(test.finalObservations)
            XCTAssertEqual(test.steps.count, 4)
            XCTAssertEqual(final.databases, ["ddlcompat"])
            XCTAssertTrue(final.cleanup.isEmpty)
        }
    }

    func testRetainedPrefixPreservesCommentBytesAndOriginalPredicates() throws {
        let test = cases[0]
        XCTAssertEqual(test.steps.count, 13)
        XCTAssertEqual(
            test.steps[8].sql, "CREATE DATABASE executable_comment_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        XCTAssertEqual(
            test.steps.suffix(4).map(\.sql),
            test.steps.prefix(4).map {
                $0.sql.replacingOccurrences(of: "ddlcompat.t", with: "executable_comment_results.ec_after_update")
            })
        XCTAssertTrue(test.steps[0].sql.hasPrefix("/*!50700 CREATE TABLE"))
        XCTAssertTrue(test.steps[0].sql.contains("DEFAULT '/*! keep */'"))
        XCTAssertEqual(
            test.steps[4].sql, "ALTER TABLE ddlcompat.t ADD last_col INT DEFAULT 9 /*!99999 , ADD future_col INT */")
        XCTAssertEqual(test.steps[5].sql, "/*! ALTER TABLE ddlcompat.t MODIFY last_col BIGINT DEFAULT 9 */")
        XCTAssertEqual(test.steps[7].sql, "DELETE FROM ddlcompat.t WHERE id=1")
        let expected: [[(String, String)]] = [
            [
                ("SELECT id,n,note,extra FROM executable_comment_results.ec_after_update", "1\t4\t/*! keep */\t7"),
                ("SELECT id,n,extra,last_col FROM ddlcompat.t", "2\t3\t7\t9"),
            ],
            [("SELECT id,n FROM ddlcompat.t", "1\t3")],
            [("SELECT id,n FROM ddlcompat.t", "1\t9")],
        ]
        for (test, old) in zip(cases, expected) {
            let final = try XCTUnwrap(test.finalObservations)
            for (sql, value) in old {
                let observation = try XCTUnwrap(final.checks.first { $0.check.sql == sql })
                XCTAssertEqual(observation.check.expected, value)
                for engine in ["InnoDB", "MyISAM"] {
                    _ = try observation.result([observation.id: value], engine: engine, role: "target")
                    XCTAssertThrowsError(
                        try observation.result([observation.id: "wrong"], engine: engine, role: "target"))
                }
            }
            XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
            XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        }
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 4)
        XCTAssertEqual(final.databases, ["ddlcompat", "executable_comment_results"])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE executable_comment_results"])
        XCTAssertTrue(final.replayResetSQL.contains("DROP DATABASE executable_comment_results"))
        XCTAssertEqual(final.checks.first { $0.id == "last-column-type" }?.check.expected, "bigint")
        for selected in [test, cases[2]] {
            let check = try XCTUnwrap(selected.finalObservations?.checks.first { $0.id == "future-column-absent" })
            XCTAssertTrue(check.check.sql.contains("COLUMN_NAME='future_col'"))
            XCTAssertEqual(check.check.expected, "0")
        }
    }

    private func writes(_ test: DDLCompatibilityCases.Case) -> [LabSQLPhase.Result] {
        let start = Boundary(file: "binlog.000003", position: 100, gtids: "uuid:1")
        return test.steps.enumerated().map { index, step in
            .init(
                write: .init(id: "statement-\(index)", sql: step.sql), start: start, end: start,
                gtids: "uuid:\(index + 1)", warnings: "")
        }
    }

    func testJournalSelectsOriginalGTIDAndPreservesLoggedCommentPredicates() throws {
        for (test, transaction) in zip(cases, [6, 2, 2]) {
            let writes = writes(test)
            let query = try ExecutableCommentWorkflowEvidence.journalSQL(test.test.id, writes: writes)
            XCTAssertTrue(query.hasSuffix("AND ddl_intents.gtid='uuid:\(transaction)'"))
            XCTAssertTrue(query.contains("source_sql=target_sql"))
            XCTAssertTrue(query.contains("status='DONE'"))
            XCTAssertEqual(
                try ExecutableCommentWorkflowEvidence.originalGTID(test.test.id, writes: writes), "uuid:\(transaction)")
            if transaction == 6 || test.test.id.hasSuffix("target-gate") {
                XCTAssertTrue(query.contains("source_sql LIKE '%/*!%ALTER%'"))
                XCTAssertTrue(query.contains("target-version-executable-comments"))
            } else {
                XCTAssertTrue(query.contains("source_sql LIKE '%/* 80000%'"))
                XCTAssertFalse(query.contains("target-version-executable-comments"))
            }
            let rewritten = writes.map {
                LabSQLPhase.Result(
                    write: .init(id: $0.write.id, sql: "server-rewritten SQL"), start: $0.start, end: $0.end,
                    gtids: $0.gtids, warnings: "")
            }
            XCTAssertEqual(try ExecutableCommentWorkflowEvidence.journalSQL(test.test.id, writes: rewritten), query)
            XCTAssertThrowsError(try ExecutableCommentWorkflowEvidence.journalSQL(test.test.id, writes: []))
            for delta in ["", "uuid:1-2"] {
                var bad = writes
                let item = bad[transaction - 1]
                bad[transaction - 1] = .init(
                    write: item.write, start: item.start, end: item.end, gtids: delta, warnings: "")
                XCTAssertThrowsError(try ExecutableCommentWorkflowEvidence.journalSQL(test.test.id, writes: bad))
            }
        }
        XCTAssertThrowsError(try ExecutableCommentWorkflowEvidence.journalSQL("unknown", writes: []))
    }

    func testJournalKeepsNonzeroAndExactOneCountRequirements() throws {
        for test in cases {
            _ = try ExecutableCommentWorkflowEvidence.journalObservation("1", caseID: test.test.id)
            for invalid in ["0", "-1", "invalid"] {
                XCTAssertThrowsError(
                    try ExecutableCommentWorkflowEvidence.journalObservation(invalid, caseID: test.test.id))
            }
            if test.test.id.hasSuffix("source-gate") {
                XCTAssertThrowsError(
                    try ExecutableCommentWorkflowEvidence.journalObservation("2", caseID: test.test.id))
            } else {
                _ = try ExecutableCommentWorkflowEvidence.journalObservation("2", caseID: test.test.id)
            }
        }
    }

    func testVersionSpecificTableCommentUsesRole() throws {
        XCTAssertEqual(
            ExecutableCommentWorkflowEvidence.tableCommentSQL,
            "SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'")
        for role in LabProfile.Role.allCases {
            let expected = role == .target ? "" : "source-only"
            let result = try ExecutableCommentWorkflowEvidence.tableComment(expected, role: role)
            XCTAssertEqual(result["value"] as? String, expected)
            XCTAssertEqual(result["expected"] as? String, expected)
            XCTAssertThrowsError(
                try ExecutableCommentWorkflowEvidence.tableComment(role == .target ? "source-only" : "", role: role))
        }
        // The forward native and external target both use MyISAM; they still differ.
        XCTAssertEqual(LabProfile.forward.engine(.native), LabProfile.forward.engine(.target))
    }
}
