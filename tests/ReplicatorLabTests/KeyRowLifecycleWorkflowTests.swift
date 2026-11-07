import XCTest

@testable import ReplicatorLabCore

final class KeyRowLifecycleWorkflowTests: XCTestCase {
    private let originals = [
        DDLCompatibilityCases.primaryKeyParts, DDLCompatibilityCases.uniqueRowIdentity,
        DDLCompatibilityCases.groupedConstraints,
    ]

    func testOriginalTransactionsAndRestartsStayBeforeEveryRetainedState() throws {
        for (original, (count, (total, tables))) in zip(originals, zip([11, 19, 13], zip([37, 93, 31], [7, 9, 8]))) {
            try KeyRowLifecycleWorkflows.validateOriginal(original)
            let test = try XCTUnwrap(KeyRowLifecycleWorkflows.plan(original))
            let snapshots = KeyRowLifecycleWorkflows.snapshots(original)
            let final = try XCTUnwrap(test.finalObservations)
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
            try final.validate(phases)
            XCTAssertEqual(original.steps.count, count)
            XCTAssertEqual(test.steps.count, total)
            XCTAssertEqual(test.steps.prefix(count).map(\.sql), original.steps.map(\.sql))
            XCTAssertEqual(test.steps.prefix(count).map(\.sqlTransactional), original.steps.map(\.sqlTransactional))
            XCTAssertEqual(test.steps.prefix(count).map(\.transactions), original.steps.map(\.transactions))
            XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore },
                original.steps.indices.filter { original.steps[$0].restartBefore })
            let observed = KeyRowLifecycleWorkflows.observations(original)
            XCTAssertEqual(phases.count, observed.count + 1)
            let live = Set(observed.values.map(\.step).filter { $0 < count })
            let retained = Set(snapshots.map(\.through))
            XCTAssertTrue(live.isDisjoint(with: retained))
            XCTAssertEqual(live.union(retained), Set(1..<count))
            XCTAssertTrue(Set(observed.keys).isSubset(of: Set(phases.map(\.id))))
            for index in original.steps.indices where original.steps[index].restartBefore {
                XCTAssertNotNil(observed["original-step-\(index)"])
                XCTAssertNotNil(observed["original-step-\(index + 1)"])
            }
            XCTAssertEqual(snapshots.flatMap(\.tables).count, tables)
            XCTAssertEqual(Set(snapshots.flatMap(\.tables)).count, tables)
            XCTAssertEqual(test.nativeInnoDB, original.nativeInnoDB)
            XCTAssertEqual(test.profileExclusions, original.profileExclusions)
            XCTAssertEqual(test.test.id, original.test.id)
            XCTAssertEqual(test.test.file, original.test.file)
            XCTAssertEqual(test.test.line, original.test.line)
            XCTAssertTrue(test.steps.dropFirst(count).allSatisfy { !$0.restartBefore && $0.checks.isEmpty })
            XCTAssertTrue(test.steps.allSatisfy { $0.assertionID == nil })
            XCTAssertEqual(final.databases, ["ddlcompat"])
            XCTAssertEqual(final.cleanup, ["DROP TABLE " + snapshots.flatMap { $0.tables.reversed() }.map { "ddlcompat." + $0 }.joined(separator: ",")])
        }
    }

    func testChangedBoundariesAndNamedAssertionsRequireAnExplicitReview() throws {
        let original = DDLCompatibilityCases.primaryKeyParts
        let changes: [(inout [DDLCompatibilityCases.Step]) -> Void] = [
            { $0.removeLast() }, { $0[2].restartBefore = false },
            { $0[1].assertionID = "new-condition" }, { $0[1].transactions = 0 },
            { $0.swapAt(4, 5) },
        ]
        for change in changes {
            var steps = original.steps
            change(&steps)
            let altered = DDLCompatibilityCases.Case("primary-key-parts", original.test.name, steps)
            XCTAssertThrowsError(try KeyRowLifecycleWorkflows.validateOriginal(altered))
        }
    }

    func testEveryEarlierStateReplaysTheOriginalPrefixOnSeparateTables() throws {
        for original in originals {
            let definition = try XCTUnwrap(KeyRowLifecycleWorkflows.definition(original.test.id))
            let test = try XCTUnwrap(KeyRowLifecycleWorkflows.plan(original))
            var index = original.steps.count
            for snapshot in KeyRowLifecycleWorkflows.snapshots(original) {
                for old in original.steps.prefix(snapshot.through) {
                    let new = test.steps[index]
                    for transactional in [false, true] {
                        let expected = KeyRowLifecycleWorkflows.renamed(
                            transactional ? old.sqlTransactional : old.sql,
                            snapshot: snapshot, definition: definition)
                        XCTAssertEqual(transactional ? new.sqlTransactional : new.sql, expected)
                    }
                    XCTAssertEqual(new.transactions, old.transactions)
                    index += 1
                }
            }
            XCTAssertEqual(index, test.steps.count)
        }
    }

    func testOriginalPredicatesKeepExpectedValuesAndEngineAdaptations() throws {
        for original in originals {
            let definition = try XCTUnwrap(KeyRowLifecycleWorkflows.definition(original.test.id))
            let test = try XCTUnwrap(KeyRowLifecycleWorkflows.plan(original))
            let final = try XCTUnwrap(test.finalObservations)
            let originalChecks = original.steps.reduce(0) { $0 + $1.checks.count }
            let observations = KeyRowLifecycleWorkflows.observations(original)
            XCTAssertEqual(final.checks.count, definition.dropsOriginalTables ? 2 : 1)
            XCTAssertEqual(observations.values.reduce(0) { $0 + $1.checks.count }, originalChecks)
            for (index, step) in original.steps.enumerated() {
                for (offset, check) in step.checks.enumerated() {
                    let observation = try XCTUnwrap(observations["original-step-\(index + 1)"]?.checks.first {
                        $0.id == "original-step-\(index + 1)-check-\(offset + 1)"
                    })
                    XCTAssertEqual(observation.check.expected, check.expected)
                    XCTAssertEqual(observation.check.myISAMExpected, check.myISAMExpected)
                    XCTAssertEqual(observation.check.fields, check.fields)
                    XCTAssertEqual(observation.check.sql, check.sql)
                }
            }
            for check in final.checks {
                let value = check.check.expected
                if check.check.fields == nil {
                    _ = try check.result([check.id: value], engine: "InnoDB", role: "target")
                }
                XCTAssertThrowsError(try check.result([check.id: "wrong"], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testRenamesAndBirthsKeepExactlyTheTablesAliveAtEachBoundary() throws {
        let prefix = KeyRowLifecycleWorkflows.snapshots(DDLCompatibilityCases.primaryKeyParts)
        XCTAssertEqual(prefix[0].tables, ["pkp_1_t"])
        XCTAssertEqual(prefix[1].tables, ["pkp_6_t", "pkp_6_copy"])
        XCTAssertEqual(prefix[2].tables, ["pkp_9_copy", "pkp_9_moved"])
        XCTAssertEqual(prefix[3].tables, ["pkp_10_copy", "pkp_10_moved"])
        let unique = KeyRowLifecycleWorkflows.snapshots(DDLCompatibilityCases.uniqueRowIdentity)
        XCTAssertEqual(unique.last?.tables, ["uri_16_t", "uri_16_seq"])
        XCTAssertNil(KeyRowLifecycleWorkflows.plan(DDLCompatibilityCases.keylessRows))
        XCTAssertTrue(KeyRowLifecycleWorkflows.observations(DDLCompatibilityCases.keylessRows).isEmpty)
    }

    func testGroupedForeignKeySymbolsAreDistinctAndTheVersionRulesStayVisible() throws {
        let original = DDLCompatibilityCases.groupedConstraints
        let plan = try XCTUnwrap(KeyRowLifecycleWorkflows.plan(original))
        XCTAssertEqual(plan.profileExclusions, original.profileExclusions)
        let foreignKeys = plan.steps.filter { $0.sqlTransactional.contains("FOREIGN KEY") }
        XCTAssertEqual(foreignKeys.count, 3)
        XCTAssertTrue(foreignKeys.allSatisfy { !$0.sql.contains("FOREIGN KEY") })
        XCTAssertEqual(foreignKeys.first?.sqlTransactional, original.steps[2].sqlTransactional)
        XCTAssertTrue(foreignKeys.dropFirst().allSatisfy { $0.sqlTransactional.contains("CONSTRAINT gc_") })
        XCTAssertEqual(Set(foreignKeys.map(\.sqlTransactional)).count, foreignKeys.count)
        let cleanup = try XCTUnwrap(plan.finalObservations).cleanup.joined()
        for snapshot in KeyRowLifecycleWorkflows.snapshots(original) where snapshot.through >= 3 {
            let child = try XCTUnwrap(cleanup.range(of: "ddlcompat.gc_\(snapshot.through)_t"))
            let parent = try XCTUnwrap(cleanup.range(of: "ddlcompat.gc_\(snapshot.through)_p"))
            XCTAssertLessThan(child.lowerBound, parent.lowerBound)
        }
    }

    func testCatalogUsesTheSharedPlanWithoutChangingSelections() throws {
        for original in originals {
            let caseInfo = try XCTUnwrap(LabScenario.correctness.first { $0.id == original.test.id })
            let test = try XCTUnwrap(KeyRowLifecycleWorkflows.plan(original))
            let liveChecks = KeyRowLifecycleWorkflows.observations(original).values.sorted { $0.step < $1.step }
                .flatMap { $0.checks.map(\.id) }
            for profile in LabProfile.allCases {
                for variant in LabVariant.allCases {
                    XCTAssertEqual(caseInfo.fields(profile, variant: variant)["assertions"] as? [String],
                        liveChecks + (test.finalObservations?.checks.map(\.id) ?? []))
                }
            }
            let query = KeyRowLifecycleWorkflows.schemaEvidenceSQL(original)
            for table in KeyRowLifecycleWorkflows.snapshots(original).flatMap(\.tables) {
                XCTAssertTrue(query.contains("'\(table)'"))
            }
        }
        XCTAssertNil(KeyRowLifecycleWorkflows.plan(DDLCompatibilityCases.jsonGeneratedIndexes))
    }

    func testAlterColumnsConstraintsAndIndexNamesHasAnExplicitCatalogName() throws {
        let id = "ddl-alter-table-columns-constraints-and-index-names"
        let test = DDLCompatibilityCases.groupedConstraints
        XCTAssertEqual(test.test.id, id)
        XCTAssertTrue(test.test.name.hasPrefix("ALTER TABLE: add columns and constraints"))
        let scenario = try XCTUnwrap(LabScenario.correctness.first { $0.id == id })
        XCTAssertEqual(scenario.fields(.reverse)["replaces"] as? [String], ["ddl-compat-grouped-constraints"])
        XCTAssertThrowsError(try LabScenario.select(tier: "full", family: nil, ids: ["ddl-compat-grouped-constraints"])) {
            XCTAssertTrue(String(describing: $0).contains("was replaced by " + id))
        }
        XCTAssertNotNil(scenario.reason(.forward))
        XCTAssertNil(scenario.reason(.reverse))
        XCTAssertNil(scenario.reason(.mysql57MyISAM))
    }
}
