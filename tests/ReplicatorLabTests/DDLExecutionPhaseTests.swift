import XCTest

@testable import ReplicatorLabCore

final class DDLExecutionPhaseTests: XCTestCase {
    func testReviewedPlansKeepStatementOrderChecksAndRestartBoundaries() throws {
        let cases = [
            DDLCompatibilityCases.columnIndexSyntax, DDLCompatibilityCases.alterColumnKeys,
            DDLCompatibilityCases.generatedDependencies, DDLCompatibilityCases.generatedExpressions,
            DDLCompatibilityCases.columnSwaps,
        ]
        for (test, counts) in zip(cases, [(20, 9, 2), (25, 14, 3), (23, 18, 4), (8, 7, 2), (15, 13, 4)]) {
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
            XCTAssertEqual(test.steps.count, counts.0)
            XCTAssertEqual(phases.count, counts.1)
            XCTAssertEqual(phases.filter { $0.steps[0].restartBefore }.count, counts.2)
            XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
            XCTAssertEqual(phases.flatMap(\.checks).map(\.sql), test.steps.flatMap(\.checks).map(\.sql))
            XCTAssertEqual(phases.flatMap(\.checks).map(\.expected), test.steps.flatMap(\.checks).map(\.expected))
            XCTAssertEqual(phases.flatMap(\.steps).reduce(0) { $0 + $1.transactions }, test.steps.count)
            XCTAssertTrue(
                phases.last!.steps.last!.sql.hasPrefix(
                    test.test.id == "ddl-compat-generated-expressions" ? "DELETE FROM" : "DROP TABLE"))
        }
        let syntax = try XCTUnwrap(DDLExecutionPhase.plan(cases[0].steps))
        XCTAssertTrue(
            syntax.first { $0.id == "renamed-column-and-index-options" }!.steps.last!.sql.hasPrefix("CREATE INDEX"))
        XCTAssertTrue(syntax.first { $0.id == "drop-index-and-copy" }!.steps.first!.sql.hasPrefix("DROP INDEX"))
        XCTAssertEqual(syntax.suffix(2).map(\.id), ["serial-row-delete", "drop-key-tables"])
        let keys = try XCTUnwrap(DDLExecutionPhase.plan(cases[1].steps))
        XCTAssertEqual(keys[2].id, "modify-primary-key")
        XCTAssertEqual(keys[3].id, "change-primary-key-name-and-position")
        XCTAssertEqual(keys[5].checks.first!.expected, "2\t2\t8")
        XCTAssertEqual(keys[6].checks.first!.expected, "2\t2\n5\t3")
    }

    func testGeneratedExpressionsAreObservedBeforeReplacementOrDrop() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.generatedDependencies.steps))
        let byName = Dictionary(uniqueKeysWithValues: phases.map { ($0.id, $0) })
        let recreated = try XCTUnwrap(byName["recreate-generated-column"])
        XCTAssertEqual(recreated.steps.map(\.sql), ["ALTER TABLE ddlcompat.q ADD g INT AS(b*2) STORED"])
        let dropped = try XCTUnwrap(byName["drop-and-rename-following-update"])
        XCTAssertEqual(dropped.steps[0].sql, "ALTER TABLE ddlcompat.q DROP g,CHANGE b c INT")
        XCTAssertEqual(phases.first!.id, "generated-chain-seed")
        XCTAssertEqual(byName["stored-to-base-conversion"]?.checks.first?.expected, "11")
        XCTAssertEqual(byName["base-to-stored-conversion"]?.checks.first?.expected, "4\t12")
        XCTAssertEqual(byName["converted-column-update-after-resume"]?.checks.first?.expected, "5\t12")
        XCTAssertEqual(
            phases.suffix(4).map(\.id),
            [
                "quoted-identifier-literal-seed", "quoted-identifier-literal-after-rename",
                "literal-row-delete", "drop-generated-tables",
            ])
        XCTAssertEqual(byName["quoted-identifier-literal-after-rename"]?.checks.first?.expected, "10\t`a`")
        XCTAssertEqual(phases.flatMap(\.checks).count, 10)
    }

    func testGeneratedPredicatesCopiesAndSwappedNamesKeepIntermediateObservations() throws {
        let expressions = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.generatedExpressions.steps))
        XCTAssertEqual(expressions.first!.steps.count, 2)
        XCTAssertEqual(
            expressions.map(\.id),
            [
                "generated-expression-seed", "expression-update-after-resume", "added-generated-predicates",
                "predicate-input-update", "copy-generated-definitions", "copy-insert-after-resume",
                "delete-original-row",
            ])
        XCTAssertEqual(expressions[2].steps.count, 1)
        XCTAssertTrue(expressions[2].steps[0].sql.hasPrefix("ALTER TABLE"))
        XCTAssertTrue(expressions[3].steps[0].sql.contains("SET n=1 WHERE id=2"))
        XCTAssertEqual(expressions[4].steps[0].sql, "CREATE TABLE ddlcompat.copy LIKE ddlcompat.t")
        XCTAssertTrue(expressions[5].steps[0].restartBefore)
        XCTAssertEqual(expressions.flatMap(\.checks).count, 4)
        let swaps = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.columnSwaps.steps))
        XCTAssertEqual(swaps.filter { $0.steps.count > 1 }.map(\.id), ["column-swap-seed", "generated-swap-seed"])
        XCTAssertEqual(
            swaps.filter { $0.steps[0].restartBefore }.map(\.id),
            [
                "swapped-key-update-after-resume", "three-column-rename-after-resume",
                "added-column-update-after-resume", "swap-generated-input-after-resume",
            ])
        XCTAssertEqual(swaps[1].checks.last!.expected, "PRIMARY\tb\nPRIMARY\ta\nka\tb\nkb\ta")
        XCTAssertEqual(swaps[5].checks.first!.expected, "11\t7\t101\t1\n20\t7\t200\t2")
        XCTAssertEqual(swaps[7].checks.first!.expected, "7\t102\t1\n7\t200\t2")
        XCTAssertEqual(
            swaps.suffix(3).map(\.id),
            ["swap-generated-input-after-resume", "generated-input-update", "drop-swapped-tables"])
        XCTAssertEqual(swaps.flatMap(\.checks).count, 11)
        XCTAssertNil(try DDLExecutionPhase.plan(DDLCompatibilityCases.foreignKeyColumnSwaps.steps))
    }

    func testPlannerRejectsHiddenObservationsRestartsAndAssertions() throws {
        typealias Step = DDLCompatibilityCases.Step
        let end = Step("UPDATE t SET v=2", phaseEnd: "updated-rows")
        XCTAssertThrowsError(
            try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", [.init("SELECT v FROM t", "1")]), end]))
        XCTAssertThrowsError(
            try DDLExecutionPhase.plan([
                Step("CREATE TABLE t(v INT)"), Step("INSERT INTO t VALUES(1)", restartBefore: true), end,
            ]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", assertionID: "insert"), end]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([end, Step("DELETE FROM t")]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([end, end]))
        XCTAssertThrowsError(try DDLExecutionPhase.plan([Step("SELECT 1", phaseEnd: "../escape")]))
        XCTAssertNil(try DDLExecutionPhase.plan([Step("INSERT INTO t VALUES(1)", restartBefore: true)]))
        XCTAssertNil(try DDLExecutionPhase.plan([]))
    }

    func testWritesResetAutoIncrementAndRetainTransactionalSQL() throws {
        let phase = DDLExecutionPhase(
            id: "transaction",
            steps: [
                .init(
                    "INSERT INTO t VALUES(1)", sqlTransactional: "BEGIN; INSERT INTO t VALUES(1); COMMIT",
                    phaseEnd: "transaction")
            ])
        XCTAssertTrue(phase.writes(transactional: true)[0].sql.hasSuffix("BEGIN; INSERT INTO t VALUES(1); COMMIT"))
        XCTAssertFalse(phase.writes(transactional: false)[0].sql.contains("COMMIT"))
        let keys = try XCTUnwrap(DDLExecutionPhase.plan(DDLCompatibilityCases.alterColumnKeys.steps))
        let writes = keys.flatMap { $0.writes(transactional: false) }
        for write in writes {
            XCTAssertTrue(
                write.sql.hasPrefix(
                    "SET SESSION auto_increment_increment=@@GLOBAL.auto_increment_increment,auto_increment_offset=@@GLOBAL.auto_increment_offset; "
                ))
        }
        XCTAssertTrue(writes[8].sql.contains("SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER"))
        XCTAssertFalse(writes[9].sql.contains("auto_increment_increment=3"))
    }

    func testBatchedExpectationsRetainWhitespaceFieldsAndEngineValues() throws {
        let phase = DDLExecutionPhase(
            id: "values",
            steps: [
                .init(
                    "SELECT 1",
                    [
                        .init("SELECT note FROM t", " a\t", myISAMExpected: " b\t"),
                        .init("SELECT a,b FROM t", "2", fields: [1]),
                    ], phaseEnd: "values")
            ])
        XCTAssertTrue(phase.queries.allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(phase.queries.map(\.name), ["check-1", "check-2"])
        let values = ["check-1": " b\t", "check-2": "ignored\t2"]
        XCTAssertEqual(try phase.observations(values, engine: "MyISAM", role: "target").count, 2)
        XCTAssertThrowsError(try phase.observations(values, engine: "InnoDB", role: "source"))
        XCTAssertThrowsError(try phase.observations(["check-1": "b"], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try phase.observations(["check-1": " b\t", "check-2": "missing-column"], engine: "MyISAM", role: "target"))
    }
}
