import XCTest

@testable import ReplicatorLabCore

final class AbsentDefinerWorkflowTests: XCTestCase {
    func testRetainedHistoryPreservesTransactionsRestartsAndSecurityChanges() throws {
        let test = DDLCompatibilityCases.absentDefiners
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 13)
        XCTAssertEqual(phases.map { $0.steps.count }, [3, 2, 8])
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [4, 6])
        XCTAssertTrue(test.steps.allSatisfy { $0.transactions == 1 && $0.sql == $0.sqlTransactional })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(test.steps[5].sql, "ALTER FUNCTION ddlcompat.f SQL SECURITY DEFINER")
        XCTAssertEqual(test.steps[6].sql, "UPDATE ddlcompat.t SET n=20 WHERE id=1")
        XCTAssertEqual(
            test.steps[7].sql, "CREATE DATABASE absent_definer_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        let names = [
            "invoker_view": "ad_invoker_view", "definer_view": "ad_definer_view", "t": "ad_invoker_base",
            "f": "ad_invoker_f",
        ]
        let expected = test.steps.prefix(5).map { step in
            names.reduce(step.sql) { sql, pair in
                sql.replacingOccurrences(of: "ddlcompat." + pair.key, with: "absent_definer_results." + pair.value)
            }
        }
        XCTAssertEqual(test.steps.suffix(5).map(\.sql), expected)
        XCTAssertTrue(test.steps.suffix(5).allSatisfy { !$0.restartBefore && !$0.sql.contains("ddlcompat.") })
        XCTAssertEqual(final.databases, ["ddlcompat", "absent_definer_results"])
        XCTAssertEqual(final.cleanup, ["DROP DATABASE absent_definer_results"])
        XCTAssertTrue(final.replayResetSQL.contains("DROP DATABASE absent_definer_results"))
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
    }

    func testOriginalPredicatesRemainAndFinalQueriesAvoidDefinerInvocation() throws {
        let final = try XCTUnwrap(DDLCompatibilityCases.absentDefiners.finalObservations)
        let expected: [(String, String, String)] = [
            ("initial-invoker-view-rows", "SELECT * FROM absent_definer_results.ad_invoker_view", "1\t10"),
            (
                "original-definer-view-metadata",
                "SELECT DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='definer_view'",
                "beta6_absent@localhost\tDEFINER"
            ),
            ("invoker-function-result", "SELECT absent_definer_results.ad_invoker_f()", "7"),
            ("updated-invoker-view-rows", "SELECT * FROM ddlcompat.invoker_view", "1\t20"),
        ]
        for (id, sql, value) in expected {
            let observation = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertEqual(observation.check.sql, sql)
            XCTAssertEqual(observation.check.expected, value)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try observation.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
            }
        }
        XCTAssertEqual(final.checks.count, 8)
        for id in ["retained-invoker-view-metadata", "retained-invoker-function-metadata"] {
            XCTAssertEqual(final.checks.first { $0.id == id }?.check.expected, "beta6_absent@localhost\tINVOKER")
        }
        XCTAssertEqual(
            final.checks.first { $0.id == "altered-function-metadata" }?.check.expected,
            "beta6_absent@localhost\tDEFINER")
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        let errors = AbsentDefinerErrorCheck.checks(stage: .beforeReplay).map(\.sql)
        XCTAssertTrue(Set(final.checks.map { $0.check.sql }).isDisjoint(with: errors))
    }

    func testEachErrorStageRoleAndObjectHasSeparateEvidence() throws {
        let checks = AbsentDefinerErrorCheck.Stage.allCases.flatMap { AbsentDefinerErrorCheck.checks(stage: $0) }
        XCTAssertEqual(checks.count, 12)
        XCTAssertEqual(Set(checks.map(\.id)).count, 12)
        XCTAssertEqual(Set(checks.map(\.outputFile)).count, 12)
        for stage in AbsentDefinerErrorCheck.Stage.allCases {
            let selected = AbsentDefinerErrorCheck.checks(stage: stage)
            XCTAssertEqual(selected.count, 6)
            for role in LabProfile.Role.allCases {
                let pair = selected.filter { $0.role == role }
                XCTAssertEqual(pair.map(\.sql), ["SELECT * FROM ddlcompat.definer_view", "SELECT ddlcompat.f()"])
                for check in pair {
                    XCTAssertEqual(
                        check.id, "absent-definer-" + stage.rawValue + "-" + role.rawValue + "-" + check.name)
                    XCTAssertEqual(check.outputFile, check.id + ".txt")
                }
            }
        }
        let final = try XCTUnwrap(DDLCompatibilityCases.absentDefiners.finalObservations)
        XCTAssertTrue(Set(checks.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
    }

    func testErrorRequires1449AndNoGTIDFileOrOffsetChange() throws {
        let before = Boundary(file: "binlog.000003", position: 190, gtids: "uuid:1-7")
        let message = "ERROR 1449 (HY000): The user specified as a definer ('beta6_absent'@'localhost') does not exist"
        func result(_ status: Int32, _ stderr: String) -> CommandResult {
            .init(stdout: Data(), stderr: Data(stderr.utf8), status: status)
        }
        let check = try XCTUnwrap(AbsentDefinerErrorCheck.checks(stage: .afterReplay).last)
        let observed = try check.observation(result(1, message), before: before, after: before)
        XCTAssertEqual(observed["sql"] as? String, "SELECT ddlcompat.f()")
        XCTAssertEqual(observed["exitStatus"] as? Int, 1)
        XCTAssertEqual(observed["stderr"] as? String, message)
        XCTAssertEqual(observed["stage"] as? String, "after-replay")
        XCTAssertEqual(observed["role"] as? String, "target")
        XCTAssertEqual(observed["outputFile"] as? String, check.outputFile)
        for boundary in ["before", "after"] {
            let value = try XCTUnwrap(observed[boundary] as? [String: Any])
            XCTAssertEqual(value["file"] as? String, before.file)
            XCTAssertEqual(value["position"] as? UInt64, before.position)
            XCTAssertEqual(value["gtid_executed"] as? String, before.gtids)
        }
        for invalid in [
            result(0, message), result(1, "ERROR 1146 (42S02): table missing"), result(1, "ERROR 14490 unknown"),
            result(1, ""),
        ] {
            XCTAssertThrowsError(try check.observation(invalid, before: before, after: before))
        }
        for after in [
            Boundary(file: "binlog.000004", position: before.position, gtids: before.gtids),
            Boundary(file: before.file, position: 191, gtids: before.gtids),
            Boundary(file: before.file, position: before.position, gtids: "uuid:1-8"),
        ] {
            XCTAssertThrowsError(try check.observation(result(1, message), before: before, after: after))
        }
    }
}
