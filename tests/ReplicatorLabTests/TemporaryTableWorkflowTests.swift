import XCTest

@testable import ReplicatorLabCore

final class TemporaryTableWorkflowTests: XCTestCase {
    private var cases: [DDLCompatibilityCases.Case] {
        [DDLCompatibilityCases.temporaryTables, DDLCompatibilityCases.temporaryCreateSelect]
    }

    func testPhasesKeepRestartsCountsEnginesAndCleanupOwnership() throws {
        for (test, sizes) in zip(cases, [[5], [3, 9]]) {
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
            let final = try XCTUnwrap(test.finalObservations)
            try final.validate(phases)
            XCTAssertEqual(phases.map { $0.steps.count }, sizes)
            XCTAssertEqual(
                test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 },
                test.test.id == "ddl-compat-temporary" ? [] : [4])
            XCTAssertTrue(test.profileExclusions.isEmpty)
            XCTAssertFalse(test.nativeInnoDB)
            XCTAssertTrue(test.steps.allSatisfy { $0.transactions == 1 && $0.assertionID == nil })
            XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
            XCTAssertEqual(final.databases, ["ddlcompat"])
            XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        }
        let like = cases[0]
        for index in [2, 4] {
            XCTAssertTrue(like.steps[index].sql.contains("ENGINE=MyISAM"))
            XCTAssertEqual(
                like.steps[index].sqlTransactional,
                like.steps[index].sql.replacingOccurrences(of: "ENGINE=MyISAM", with: "ENGINE=InnoDB"))
        }
        XCTAssertEqual(
            like.steps[4].sql,
            like.steps[2].sql.replacingOccurrences(of: "ddlcompat.cloned", with: "ddlcompat.tt_empty_clone"))
        XCTAssertEqual(like.finalObservations?.cleanup, ["DROP TABLE ddlcompat.tt_empty_clone"])
        XCTAssertEqual(
            cases[1].finalObservations?.cleanup, ["DROP TABLE ddlcompat.tt_ctas_inserted,ddlcompat.tt_ctas_updated"])
        let ordered = DDLCompatibilityCases.cases.map { $0.test.id }
        XCTAssertEqual(ordered.last, "ddl-compat-temporary")
        XCTAssertLessThan(
            try XCTUnwrap(ordered.firstIndex(of: "ddl-compat-temporary-create-select")),
            try XCTUnwrap(ordered.firstIndex(of: "ddl-compat-temporary")))
    }

    func testTemporaryScriptsRemainWholeAndDropBeforeClientReuse() throws {
        for transactional in [false, true] {
            var scripts = 0
            for test in cases {
                for phase in try XCTUnwrap(DDLExecutionPhase.plan(test.steps)) {
                    let writes = phase.writes(transactional: transactional)
                    let queries = try LabSQLPhase.queries(
                        writes, session: "SET NAMES utf8mb4", status: "SHOW MASTER STATUS")
                    XCTAssertEqual(queries.count, writes.count * 4)
                    for (step, write) in zip(phase.steps, writes) {
                        let original = transactional ? step.sqlTransactional : step.sql
                        XCTAssertTrue(write.sql.hasSuffix(original))
                        XCTAssertFalse(write.sql.contains("BEGIN"))
                        XCTAssertFalse(write.sql.contains("COMMIT"))
                        if original.contains("CREATE TEMPORARY TABLE") {
                            scripts += 1
                            XCTAssertTrue(original.hasPrefix("USE ddlcompat; CREATE TEMPORARY TABLE tmp"))
                            XCTAssertTrue(original.hasSuffix("DROP TEMPORARY TABLE tmp"))
                            XCTAssertEqual(original.components(separatedBy: "DROP TEMPORARY TABLE tmp").count, 2)
                            let request = try XCTUnwrap(queries.first { $0.name == write.id + "/warnings" })
                            XCTAssertTrue(request.sql.contains(original + "; SHOW WARNINGS"))
                            let input = try LabSQLInput(
                                request.sql, resetGTID: false, script: false, delimiter: "_temporary_")
                            XCTAssertEqual(input.arguments, ["--delimiter=_temporary_"])
                            XCTAssertTrue(String(decoding: input.bytes, as: UTF8.self).contains(original))
                        }
                    }
                }
            }
            XCTAssertEqual(scripts, 8)
        }
    }

    func testRetainedSelectBindingsPreserveSelectAndJoinOperations() {
        let steps = cases[1].steps
        XCTAssertEqual(steps.count, 12)
        XCTAssertEqual(
            steps[2].sql,
            "USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM t; UPDATE tmp SET n=n+1; INSERT INTO t SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp"
        )
        XCTAssertEqual(
            steps[3].sql,
            "USE ddlcompat; CREATE TEMPORARY TABLE tmp SELECT * FROM t WHERE 0; INSERT INTO tmp VALUES(99,99); UPDATE t JOIN tmp ON t.id=tmp.id-98 SET t.n=tmp.n; DROP TEMPORARY TABLE tmp"
        )
        for (range, table) in [(5..<8, "tt_ctas_inserted"), (8..<12, "tt_ctas_updated")] {
            let history = Array(steps[range])
            XCTAssertEqual(history[0].sql, "CREATE TABLE ddlcompat.\(table)(id INT PRIMARY KEY,n INT)")
            XCTAssertEqual(history[1].sql, "INSERT INTO ddlcompat.\(table) VALUES(1,10),(2,20)")
            XCTAssertEqual(
                history[2].sql,
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM \(table); UPDATE tmp SET n=n+1; INSERT INTO \(table) SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp"
            )
            XCTAssertTrue(history.allSatisfy { !$0.restartBefore && $0.sql == $0.sqlTransactional })
            if history.count == 4 {
                XCTAssertEqual(
                    history[3].sql,
                    "USE ddlcompat; CREATE TEMPORARY TABLE tmp SELECT * FROM \(table) WHERE 0; INSERT INTO tmp VALUES(99,99); UPDATE \(table) JOIN tmp ON \(table).id=tmp.id-98 SET \(table).n=tmp.n; DROP TEMPORARY TABLE tmp"
                )
            }
        }
    }

    func testAllSevenOldPredicatesAndPermanentSameNameRowRemain() throws {
        let expected: [[(String, String)]] = [
            [
                ("SELECT * FROM ddlcompat.t ORDER BY id", "1\t7\n2\t8"),
                ("SELECT COUNT(*) FROM ddlcompat.tt_empty_clone", "0"), ("SELECT * FROM ddlcompat.cloned", "3\t9"),
                ("SELECT * FROM ddlcompat.tmp", "99\t99"),
            ],
            [
                ("SELECT * FROM ddlcompat.tt_ctas_inserted ORDER BY id", "1\t10\n2\t20\n11\t11\n12\t21"),
                (
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='tmp'",
                    "0"
                ), ("SELECT * FROM ddlcompat.tt_ctas_updated ORDER BY id", "1\t99\n2\t20\n11\t11\n12\t21"),
                ("SELECT * FROM ddlcompat.t ORDER BY id", "1\t99\n11\t11\n12\t21"),
            ],
        ]
        for (test, values) in zip(cases, expected) {
            let final = try XCTUnwrap(test.finalObservations)
            XCTAssertEqual(final.checks.count, 4)
            for (sql, value) in values {
                let observation = try XCTUnwrap(final.checks.first { $0.check.sql == sql })
                XCTAssertEqual(observation.check.expected, value)
                for engine in ["InnoDB", "MyISAM"] {
                    _ = try observation.result([observation.id: value], engine: engine, role: "target")
                    XCTAssertThrowsError(
                        try observation.result([observation.id: "wrong"], engine: engine, role: "target"))
                }
            }
        }
        let setup = TemporaryTableWorkflowEvidence.additionalSetup("ddl-compat-temporary")
        XCTAssertEqual(
            setup.map(\.sql),
            ["CREATE TABLE ddlcompat.tmp(id INT PRIMARY KEY,n INT)", "INSERT INTO ddlcompat.tmp VALUES(99,99)"])
        for id in ["ddl-compat-temporary-create-select", "ddl-compat-views", "other"] {
            XCTAssertTrue(TemporaryTableWorkflowEvidence.additionalSetup(id).isEmpty)
        }
    }

    func testEngineExceptionOnlyAllowsOwnedSourceClones() {
        for profile in LabProfile.allCases {
            for role in LabProfile.Role.allCases {
                for table in ["cloned", "tt_empty_clone", "t", "tmp", "other", "Cloned"] {
                    let expected =
                        !profile.transactionalTarget && role == .source && ["cloned", "tt_empty_clone"].contains(table)
                    XCTAssertEqual(
                        TemporaryTableWorkflowEvidence.explicitMyISAMClone(
                            profile: profile, role: role, database: "ddlcompat", table: table), expected)
                    XCTAssertFalse(
                        TemporaryTableWorkflowEvidence.explicitMyISAMClone(
                            profile: profile, role: role, database: "other", table: table))
                }
            }
        }
    }

    func testCleanupAuditRequiresPositiveCountWithoutFixingItsTotal() throws {
        XCTAssertEqual(
            TemporaryTableWorkflowEvidence.cleanupSQL,
            "SELECT COUNT(*) FROM ddl_skips WHERE reason='row replication temporary-table cleanup'")
        for count in ["1", "5", "100"] {
            let observed = try TemporaryTableWorkflowEvidence.cleanupObservation(count)
            XCTAssertEqual(observed["count"] as? String, count)
            XCTAssertEqual(observed["reason"] as? String, "row replication temporary-table cleanup")
        }
        for invalid in ["0", "-1", "", "unknown"] {
            XCTAssertThrowsError(try TemporaryTableWorkflowEvidence.cleanupObservation(invalid))
        }
    }
}
