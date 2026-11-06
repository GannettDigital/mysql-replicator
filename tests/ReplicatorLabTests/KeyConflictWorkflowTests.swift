import Foundation
import XCTest

@testable import ReplicatorLabCore

final class KeyConflictWorkflowTests: XCTestCase {
    func testPlanKeepsAllConflictStatesSourceStatementsAndUnloggedFlags() throws {
        let original = DDLCompatibilityCases.keyConflicts
        let execution = try XCTUnwrap(KeyConstraintWorkflows.plan(original))
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(execution.test.steps))
        XCTAssertEqual(phases.map(\.id), ["key-changes", "retain-key-states"])
        XCTAssertEqual(phases[0].steps.map(\.sql), original.steps.map(\.sql))
        XCTAssertEqual(phases[0].steps.map(\.transactions), original.steps.map(\.transactions))
        XCTAssertEqual(phases[0].steps.last?.transactions, 0, "A phase end must keep the unlogged flag")
        XCTAssertEqual(phases[1].steps.count, 15)
        XCTAssertTrue(phases[1].steps.allSatisfy { $0.transactions == 1 })
        XCTAssertEqual(execution.test.steps.count, 26)
        XCTAssertEqual(execution.transactions, 24)
        XCTAssertEqual(execution.ddl, 11)
        XCTAssertEqual(execution.rows, 22)
        XCTAssertEqual(execution.states.count, 11)
        XCTAssertEqual(Set(execution.states.map(\.table)).count, 11)
        XCTAssertEqual(
            execution.states.filter(\.unlogged).map(\.assertion), ["insert-on-duplicate-noop", "insert-ignore-noop"])
        XCTAssertTrue(execution.states.filter(\.unlogged).allSatisfy { $0.affectedRows == 0 })
        let final = try XCTUnwrap(execution.test.finalObservations)
        XCTAssertEqual(final.checks.map(\.id), original.steps.compactMap(\.assertionID))
        XCTAssertEqual(original.steps.reduce(0) { $0 + $1.checks.count }, 8)
        XCTAssertEqual(execution.test.test.file, original.test.file)
        XCTAssertEqual(execution.test.test.line, original.test.line)
        XCTAssertTrue(execution.test.profileExclusions.isEmpty)
        let tables = try XCTUnwrap(KeyConstraintWorkflows.tables(original.test.id))
        var history: [String] = []
        for table in tables {
            for (offset, state) in table.states.enumerated() where state.table != table.name {
                history += original.steps[table.steps.lowerBound...table.steps.lowerBound + offset].map {
                    KeyConstraintWorkflows.rename($0.sql, from: table.name, to: state.table)
                }
            }
        }
        XCTAssertEqual(phases[1].steps.map(\.sql), history)
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        for table in tables {
            for (offset, index) in table.steps.enumerated() {
                let state = table.states[offset]
                let observation = try XCTUnwrap(final.checks.first { $0.id == state.assertion })
                if let source = original.steps[index].checks.first {
                    XCTAssertEqual(
                        observation.check.sql,
                        KeyConstraintWorkflows.rename(source.sql, from: table.name, to: state.table))
                    XCTAssertEqual(observation.check.expected, source.expected)
                } else {
                    XCTAssertTrue(observation.check.expected.hasPrefix("0\n"))
                    XCTAssertTrue(observation.check.expected.hasSuffix("PRIMARY:0:1:id\nuk:0:1:v"))
                }
            }
        }
    }

    func testPlanRejectsUnloggedDDLMutationsOrChangedTransactionFlags() throws {
        let original = DDLCompatibilityCases.keyConflicts
        let tables = try XCTUnwrap(KeyConstraintWorkflows.tables(original.test.id))
        let changes: [(inout [KeyConstraintWorkflows.Table]) -> Void] = [
            { $0[0].states[3].affectedRows = 1 },
            { $0[0].states[3].unlogged = false },
            { $0[0].states[3].createMetadata = "not a CREATE" },
        ]
        for change in changes {
            var changed = tables
            change(&changed)
            XCTAssertThrowsError(try KeyConstraintWorkflows.plan(original, tables: changed))
        }
        var steps = original.steps
        steps[0].transactions = 0
        var changed = tables
        changed[0].states[0].unlogged = true
        let invalid = DDLCompatibilityCases.Case("key-conflicts", original.test.name, steps)
        XCTAssertThrowsError(try KeyConstraintWorkflows.plan(invalid, tables: changed))
        steps = original.steps
        steps[3].transactions = 1
        XCTAssertThrowsError(
            try KeyConstraintWorkflows.plan(.init("key-conflicts", original.test.name, steps), tables: tables))
    }

    func testCheckpointKeepsTwoEmptyDeltasAndRejectsAnyFalseUnloggedBoundary() throws {
        let steps: [DDLCompatibilityCases.Step] = [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY)"),
            .init("UPDATE ddlcompat.t SET id=1 WHERE id=1", transactions: 0),
            .init("DELETE FROM ddlcompat.t WHERE id=1", transactions: 0),
        ]
        let execution = KeyConstraintWorkflows.Execution(
            test: .init("checkpoint-test", "Unlogged ending", steps),
            states: [.init(table: "t", assertion: "created", rows: 0, affectedRows: 0)], ddl: 1, rows: 0)
        let point = Boundary(file: "binlog.000001", position: 200, gtids: "uuid:1-2")
        let writes = [
            LabSQLPhase.Result(
                write: .init(id: "create", sql: steps[0].sql),
                start: .init(file: point.file, position: 100, gtids: "uuid:1"), end: point,
                gtids: "uuid:2", warnings: ""),
            .init(write: .init(id: "noop-one", sql: steps[1].sql), start: point, end: point, gtids: "", warnings: ""),
            .init(
                write: .init(id: "noop-two", sql: steps[2].sql), start: point, end: point, gtids: "",
                warnings: "Warning\t1062\tfixture warning"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner(root: directory)
        let file = directory.appendingPathComponent("state.sqlite")
        var queries: [String] = []
        func query(_ sql: String) throws -> String {
            queries.append(sql)
            return try runner.run(["sqlite3", file.path, sql]).text
        }
        _ = try query(
            """
            CREATE TABLE groups(gtid TEXT,status TEXT,source_file TEXT,end_position TEXT);
            INSERT INTO groups VALUES('uuid:2','APPLIED','binlog.000001','200');
            CREATE TABLE ddl_intents(gtid TEXT,status TEXT);
            INSERT INTO ddl_intents VALUES('uuid:2','DONE');
            CREATE TABLE row_intents(gtid TEXT,status TEXT);
            CREATE TABLE state(lifecycle TEXT,applied_file TEXT,applied_position TEXT);
            INSERT INTO state VALUES('STOPPED','binlog.000001','200');
            CREATE TABLE schemas(current INTEGER,schema_json TEXT);
            INSERT INTO schemas VALUES(1,'{"database":"ddlcompat","table":"t"}');
            """)
        let before: [String: Any] = ["transactionsApplied": 0, "ddlApplied": 0, "rowsApplied": 0]
        let after: [String: Any] = ["transactionsApplied": 1, "ddlApplied": 1, "rowsApplied": 0]
        queries.removeAll()
        let result = try execution.checkpoint(writes: writes, before: before, after: after, query: query)
        XCTAssertEqual(result["transactions"] as? Int, 1)
        XCTAssertEqual(result["unloggedOperations"] as? Int, 2)
        XCTAssertEqual((result["unloggedWrites"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(queries.contains { $0.contains("gtid=''") || $0.contains("IN ('')") })
        XCTAssertTrue(queries.contains { $0.contains("gtid IN ('uuid:2')") })
        let phase = DDLExecutionPhase(id: "unlogged", steps: steps)
        XCTAssertEqual(try phase.validateUnlogged(writes), 2)
        for (delta, end) in [
            ("uuid:3", point),
            ("", Boundary(file: point.file, position: point.position, gtids: "uuid:1-3")),
            ("", Boundary(file: "binlog.000002", position: point.position, gtids: point.gtids)),
            ("", Boundary(file: point.file, position: 201, gtids: point.gtids)),
        ] {
            var bad = writes
            bad[1] = .init(write: writes[1].write, start: point, end: end, gtids: delta, warnings: "")
            queries.removeAll()
            XCTAssertThrowsError(try phase.validateUnlogged(bad))
            XCTAssertThrowsError(try execution.checkpoint(writes: bad, before: before, after: after, query: query))
            XCTAssertTrue(queries.isEmpty)
        }
        var bad = writes
        bad[0] = .init(write: writes[0].write, start: writes[0].start, end: point, gtids: "uuid:2-3", warnings: "")
        XCTAssertThrowsError(try execution.checkpoint(writes: bad, before: before, after: after, query: query))
        var wrong = after
        wrong["transactionsApplied"] = 3
        XCTAssertThrowsError(try execution.checkpoint(writes: writes, before: before, after: wrong, query: query))
    }
}
