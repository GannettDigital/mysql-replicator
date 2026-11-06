import Foundation
import XCTest

@testable import ReplicatorLabCore

final class KeyConstraintWorkflowTests: XCTestCase {
    private func original(_ id: String) throws -> DDLCompatibilityCases.Case {
        try XCTUnwrap(DDLCompatibilityCases.cases.first { $0.test.id == id })
    }

    func testBothPlansKeepEveryOriginalOperationAndReplayOnlyItsTablePrefix() throws {
        for (id, statements, ddl, rows, predicates, names) in [
            ("ddl-compat-primary-key-row-matching", 25, 9, 27, 7, 9),
            ("ddl-compat-constraints", 65, 38, 48, 9, 6),
        ] {
            let source = try original(id)
            let tables = try XCTUnwrap(KeyConstraintWorkflows.tables(id))
            let execution = try XCTUnwrap(KeyConstraintWorkflows.plan(source))
            XCTAssertEqual(execution.test.test.id, source.test.id)
            XCTAssertEqual(execution.test.test.name, source.test.name)
            XCTAssertEqual(execution.test.test.file, source.test.file)
            XCTAssertEqual(execution.test.test.line, source.test.line)
            XCTAssertEqual(execution.test.profileExclusions, source.profileExclusions)
            XCTAssertEqual(execution.test.nativeInnoDB, source.nativeInnoDB)
            XCTAssertEqual(execution.test.steps.count, statements)
            XCTAssertEqual(execution.ddl, ddl)
            XCTAssertEqual(execution.rows, rows)
            let phases = try XCTUnwrap(DDLExecutionPhase.plan(execution.test.steps))
            XCTAssertEqual(phases.map(\.id), ["key-changes", "retain-key-states"])
            XCTAssertEqual(phases[0].steps.map(\.sql), source.steps.map(\.sql))
            var history: [String] = []
            for table in tables {
                for (offset, state) in table.states.enumerated() where state.table != table.name {
                    history += source.steps[table.steps.lowerBound...table.steps.lowerBound + offset].map {
                        KeyConstraintWorkflows.rename($0.sql, from: table.name, to: state.table)
                    }
                }
            }
            XCTAssertEqual(phases[1].steps.map(\.sql), history)
            XCTAssertTrue(
                execution.test.steps.allSatisfy {
                    $0.assertionID == nil && $0.checks.isEmpty && !$0.restartBefore && $0.transactions == 1
                        && $0.sql == $0.sqlTransactional
                })
            let final = try XCTUnwrap(execution.test.finalObservations)
            XCTAssertEqual(final.checks.count, source.steps.count)
            XCTAssertEqual(Set(execution.states.map(\.table)).count, source.steps.count)
            XCTAssertEqual(final.checks.map(\.id), execution.states.map(\.assertion))
            XCTAssertEqual(execution.states.filter(\.named).map(\.assertion), source.steps.compactMap(\.assertionID))
            XCTAssertEqual(execution.states.filter(\.named).count, names)
            XCTAssertEqual(source.steps.reduce(0) { $0 + $1.checks.count }, predicates)
            XCTAssertEqual(final.databases, ["ddlcompat"])
            XCTAssertTrue(final.cleanup.isEmpty)
            XCTAssertNoThrow(try final.validate(phases))
        }
        XCTAssertNil(try KeyConstraintWorkflows.plan(DDLCompatibilityCases.primaryKeyParts))
    }

    func testEveryPredicateAndCreateMetadataSurvivesAtItsExactState() throws {
        for id in ["ddl-compat-primary-key-row-matching", "ddl-compat-constraints", "ddl-compat-key-conflicts"] {
            let source = try original(id)
            let tables = try XCTUnwrap(KeyConstraintWorkflows.tables(id))
            let execution = try XCTUnwrap(KeyConstraintWorkflows.plan(source))
            let final = try XCTUnwrap(execution.test.finalObservations)
            for table in tables {
                for (offset, index) in table.steps.enumerated() {
                    let state = table.states[offset]
                    let observation = try XCTUnwrap(final.checks.first { $0.id == state.assertion })
                    if let check = source.steps[index].checks.first {
                        XCTAssertEqual(
                            observation.check.sql,
                            KeyConstraintWorkflows.rename(check.sql, from: table.name, to: state.table))
                        XCTAssertEqual(observation.check.expected, check.expected)
                        XCTAssertEqual(observation.check.fields, check.fields)
                        XCTAssertEqual(observation.check.myISAMExpected, check.myISAMExpected)
                    } else if let metadata = state.createMetadata {
                        XCTAssertEqual(observation.check.expected, "0\n" + metadata)
                        XCTAssertTrue(observation.check.sql.contains("information_schema.COLUMNS"))
                        XCTAssertTrue(observation.check.sql.contains("information_schema.STATISTICS"))
                    } else {
                        XCTAssertEqual(observation.check.sql, "SELECT COUNT(*) FROM ddlcompat." + state.table)
                        XCTAssertEqual(observation.check.expected, String(state.rows))
                    }
                    for role in ["source", "native", "target"] {
                        XCTAssertNoThrow(
                            try observation.result(
                                [state.assertion: observation.check.expected], engine: "MyISAM", role: role))
                        XCTAssertThrowsError(
                            try observation.result([state.assertion: "wrong"], engine: "InnoDB", role: role))
                    }
                }
            }
        }
        let sql = "USE ddlcompat; ALTER TABLE aux ADD CONSTRAINT val_uni UNIQUE(val)"
        XCTAssertEqual(
            KeyConstraintWorkflows.rename(sql, from: "aux", to: "retained"),
            "USE ddlcompat; ALTER TABLE retained ADD CONSTRAINT val_uni UNIQUE(val)")
        XCTAssertEqual(
            KeyConstraintWorkflows.rename("WHERE TABLE_NAME='aux'", from: "aux", to: "retained"),
            "WHERE TABLE_NAME='retained'")
    }

    func testPlannerRejectsMissingStatesDuplicateNamesAndBrokenNamedMappings() throws {
        let source = DDLCompatibilityCases.primaryKeyRowMatching
        let tables = try XCTUnwrap(KeyConstraintWorkflows.tables(source.test.id))
        let tableChanges: [(inout [KeyConstraintWorkflows.Table]) -> Void] = [
            { $0[0].states.removeLast() },
            { $0[0].states[0].table = $0[0].states[1].table },
            { $0[0].states[0].assertion = $0[0].states[1].assertion },
            { $0[0].states[0].assertion = "unknown" },
            { $0[0].states[0].named = false },
            { $0[0].states[0].createMetadata = nil },
            { $0[0].states[1].createMetadata = "not a CREATE" },
            { $0[0].steps = 1..<6 },
            { $0[0].states[0].table = "unsafe.table" },
        ]
        for change in tableChanges {
            var changed = tables
            change(&changed)
            XCTAssertThrowsError(try KeyConstraintWorkflows.plan(source, tables: changed))
        }
        let stepChanges: [(inout [DDLCompatibilityCases.Step]) -> Void] = [
            { $0[0].assertionID = nil }, { $0[0].transactions = 0 }, { $0[0].restartBefore = true },
        ]
        for change in stepChanges {
            var steps = source.steps
            change(&steps)
            let changed = DDLCompatibilityCases.Case("primary-key-row-matching", source.test.name, steps)
            XCTAssertThrowsError(try KeyConstraintWorkflows.plan(changed, tables: tables))
        }
        var steps = source.steps
        let last = steps.removeLast()
        steps.append(.init(last.sql, phaseEnd: "end"))
        XCTAssertThrowsError(try DDLExecutionPhase.plan(steps), "The generic named-step guard must remain strict")
    }

    func testCheckpointRequiresEveryAppliedOffsetCounterIntentAndSavedTable() throws {
        let execution = try XCTUnwrap(KeyConstraintWorkflows.plan(DDLCompatibilityCases.primaryKeyRowMatching))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner(root: directory)
        let file = directory.appendingPathComponent("state.sqlite")
        func query(_ sql: String) throws -> String { try runner.run(["sqlite3", file.path, sql]).text }
        let writes = execution.test.steps.enumerated().map { i, step in
            LabSQLPhase.Result(
                write: .init(id: "statement-\(i)", sql: step.sql),
                start: .init(file: "binlog.000001", position: UInt64(100 + i * 10), gtids: "uuid:1"),
                end: .init(file: "binlog.000001", position: UInt64(110 + i * 10), gtids: "uuid:1-\(i + 2)"),
                gtids: "uuid:\(i + 2)", warnings: "")
        }
        _ = try query(
            """
            CREATE TABLE groups(gtid TEXT,status TEXT,source_file TEXT,end_position TEXT);
            CREATE TABLE ddl_intents(gtid TEXT,status TEXT);
            CREATE TABLE row_intents(gtid TEXT,status TEXT);
            CREATE TABLE state(lifecycle TEXT,applied_file TEXT,applied_position TEXT);
            CREATE TABLE schemas(current INTEGER,schema_json TEXT);
            INSERT INTO state VALUES('STOPPED','binlog.000001','\(writes.last!.end.position)');
            """
                + writes.map {
                    "INSERT INTO groups VALUES('\($0.gtids)','APPLIED','binlog.000001','\($0.end.position)');"
                }.joined()
                + (0..<execution.ddl).map { "INSERT INTO ddl_intents VALUES('\(writes[$0].gtids)','DONE');" }.joined()
                + (0..<execution.rows).map { _ in "INSERT INTO row_intents VALUES('\(writes.last!.gtids)','DONE');" }
                .joined()
                + execution.states.map {
                    "INSERT INTO schemas VALUES(1,'{\"database\":\"ddlcompat\",\"table\":\"\($0.table)\"}');"
                }.joined())
        let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 0]
        let after: [String: Any] = ["transactionsApplied": 27, "ddlApplied": 10, "rowsApplied": 27]
        XCTAssertNoThrow(try execution.checkpoint(writes: writes, before: before, after: after, query: query))
        XCTAssertThrowsError(try execution.checkpoint(writes: [], before: before, after: after, query: query))
        XCTAssertThrowsError(
            try execution.checkpoint(
                writes: Array(writes.dropLast()) + [writes[0]], before: before, after: after, query: query))
        var wrong = after
        wrong["rowsApplied"] = 28
        XCTAssertThrowsError(try execution.checkpoint(writes: writes, before: before, after: wrong, query: query))
        for mutation in [
            "UPDATE groups SET end_position='wrong' WHERE rowid=1",
            "UPDATE groups SET status='PENDING' WHERE rowid=1",
            "DELETE FROM groups WHERE rowid=1",
            "UPDATE ddl_intents SET status='PENDING' WHERE rowid=1",
            "DELETE FROM ddl_intents WHERE rowid=1",
            "UPDATE row_intents SET status='PENDING' WHERE rowid=1",
            "DELETE FROM row_intents WHERE rowid=1",
            "INSERT INTO row_intents VALUES('\(writes.last!.gtids)','DONE')",
            "UPDATE state SET applied_position='0'",
            "UPDATE schemas SET current=0 WHERE rowid=1",
            "INSERT INTO schemas SELECT * FROM schemas WHERE rowid=1",
        ] {
            let backup = directory.appendingPathComponent("before.sqlite")
            try FileManager.default.copyItem(at: file, to: backup)
            _ = try query(mutation)
            XCTAssertThrowsError(
                try execution.checkpoint(writes: writes, before: before, after: after, query: query), mutation)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
    }
}
