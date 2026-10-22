import Foundation
import XCTest

@testable import ReplicatorLabCore

final class LabSQLTraceTests: XCTestCase {
    private func fixture(_ body: (URL, LabSQLTrace) throws -> Void) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        try body(output, LabSQLTrace(output: output))
    }
    private func records(_ output: URL) throws -> [[String: Any]] {
        try Data(contentsOf: output.appendingPathComponent("sql-trace.jsonl")).split(separator: 0x0A).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
    }
    private func success() -> CommandResult { CommandResult(stdout: Data(), stderr: Data(), status: 0) }

    func testRecordsBeforeExecutionAndRestoresNestedCaseAndAssertionContext() throws {
        try fixture { output, trace in
            let reporter = QualificationReporter(output: output, sqlTrace: trace) { _ in }
            let request = LabSQLTrace.Request(service: "source", sql: "SELECT 'a;\\nb'")
            _ = try trace.measure(request) {
                XCTAssertEqual(try records(output).last?["event"] as? String, "start")
                return success()
            }
            try reporter.run(QualificationCase("parent", "Parent")) {
                try reporter.run(QualificationCase("child", "Child")) {
                    try reporter.assertion("rows", evidence: "rows.json") {
                        _ = try trace.measure(request, success)
                        return ["matched": true]
                    }
                }
                _ = try trace.measure(request, success)
            }
            _ = try trace.measure(request, success)
            let saved = try records(output)
            let starts = saved.filter { $0["event"] as? String == "start" }
            XCTAssertEqual(starts[0]["scope"] as? String, "outside-case")
            XCTAssertEqual(starts[1]["case_path"] as? [String], ["parent", "child"])
            XCTAssertEqual(starts[1]["assertion_id"] as? String, "rows")
            XCTAssertEqual(starts[1]["sql"] as? String, request.sql)
            XCTAssertEqual(starts[2]["case_id"] as? String, "parent")
            XCTAssertNil(starts[2]["assertion_id"])
            XCTAssertNil(starts[3]["case_id"])
            XCTAssertEqual(saved[0]["call_id"] as? String, saved[1]["call_id"] as? String)
            XCTAssertEqual(Set(starts.compactMap { $0["call_id"] as? String }).count, 4)
        }
    }
    func testErrorsAndFailedClientsRemainDistinctFromTestOutcome() throws {
        try fixture { output, trace in
            let reporter = QualificationReporter(output: output, sqlTrace: trace) { _ in }
            try reporter.begin(QualificationCase("negative", "Expected error"))
            XCTAssertThrowsError(
                try reporter.assertion("timeout", evidence: "timeout.json") {
                    try trace.measure(.init(service: "target57", sql: "SELECT 1")) { throw LabError("timeout") }
                })
            _ = reporter.fail(LabError("timeout"))
            _ = try trace.measure(.init(service: "target57", sql: "INVALID SQL")) {
                CommandResult(stdout: Data(), stderr: Data("syntax error".utf8), status: 1)
            }
            let saved = try records(output)
            XCTAssertEqual(saved[1]["outcome"] as? String, "error")
            XCTAssertNil(saved[1]["exit_code"])
            XCTAssertNil(saved[2]["case_id"])
            XCTAssertNil(saved[2]["assertion_id"])
            XCTAssertEqual(saved[3]["outcome"] as? String, "failed")
            XCTAssertEqual(saved[3]["exit_code"] as? Int, 1)
            XCTAssertEqual(saved[3]["error"] as? String, "syntax error")
        }
    }
    func testBatchNamesScriptsAndReverseRoles() throws {
        try fixture { output, trace in
            let f = LabFixture(root: output, profile: .reverse)
            trace.roles = f.h.sqlTrace.roles
            trace.metadata = f.h.sqlTrace.metadata
            let batch = LabSQLBatch(queries: [
                .init(name: "rows", sql: "SELECT * FROM t"), .init(name: "schema", sql: "SHOW CREATE TABLE t"),
            ])
            _ = try trace.measure(
                .init(service: "target57", sql: batch.statement, kind: "batch", queries: batch.queries), success)
            let script = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;"
            _ = try trace.measure(.init(service: "source", sql: script, kind: "script", resetsGTID: true), success)
            let saved = try records(output)
            XCTAssertEqual(saved[0]["role"] as? String, "source")
            XCTAssertEqual(saved[0]["profile"] as? String, LabProfile.reverse.rawValue)
            XCTAssertEqual((saved[0]["queries"] as? [[String: String]])?.map { $0["name"]! }, ["rows", "schema"])
            XCTAssertEqual(saved[2]["role"] as? String, "target")
            XCTAssertEqual(saved[2]["sql"] as? String, script)
            XCTAssertEqual(saved[2]["resets_gtid"] as? Bool, true)
        }
    }
    func testDirectClientsAndDetachedCommands() throws {
        try fixture { output, trace in
            let args = [
                "exec", "-d", "-e", "MYSQL_PWD=fixture", "target57", "mysql", "--no-defaults", "-uroot", "-e",
                "DO SLEEP(10)",
            ]
            let request = try XCTUnwrap(LabSQLTrace.Request.compose(args, input: nil))
            XCTAssertEqual(request.sql, "DO SLEEP(10)")
            XCTAssertEqual(request.service, "target57")
            XCTAssertTrue(request.detached)
            _ = try trace.measure(request, success)
            XCTAssertEqual(try records(output)[1]["outcome"] as? String, "submitted")
            XCTAssertNil(LabSQLTrace.Request.compose(["exec", "-T", "source", "mysqlbinlog", "file"], input: nil))
            XCTAssertNil(LabSQLTrace.Request.compose(["logs", "source"], input: nil))
        }
    }
    func testTraceWriteFailurePreventsAnUnrecordedSQLCall() throws {
        try fixture { output, trace in
            try Data("file, not directory".utf8).write(to: output)
            var called = false
            XCTAssertThrowsError(
                try trace.measure(.init(service: "source", sql: "SELECT 1")) {
                    called = true
                    return success()
                })
            XCTAssertFalse(called)
        }
    }
}
