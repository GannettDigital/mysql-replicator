import Foundation
import XCTest
@testable import ReplicatorLabCore

final class QualificationReporterTests: XCTestCase {
    func testCaseLocationPointsToDefinitionRatherThanReporter() {
        let definitionLine = #line + 1
        let test = QualificationCase("add-column", "ADD column inherits charset")
        XCTAssertEqual(test.file, "tests/ReplicatorLabTests/QualificationReporterTests.swift")
        XCTAssertEqual(test.line, UInt(definitionLine))
    }

    func testPassIsPublishedOnlyAfterAssertionsComplete() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        var messages: [String] = []
        let reporter = QualificationReporter(output: output) { messages.append($0) }
        let test = QualificationCase("truncate", "TRUNCATE retains schema and removes rows")
        try reporter.run(test) {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cases.json"))) as! [[String: Any]]
            XCTAssertEqual(saved[0]["status"] as? String, "running")
            XCTAssertFalse(messages.contains { $0.hasPrefix("passed") })
        }
        XCTAssertEqual(reporter.results[0]["status"] as? String, "passed")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reporter.results[0]["seconds"] as? Double), 0)
        XCTAssertEqual(messages, ["starting " + test.description, "passed " + test.description])
    }

    func testFailedAssertionPreservesCaseAndParentInSavedEvidence() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        var messages: [String] = []
        let reporter = QualificationReporter(output: output) { messages.append($0) }
        let parent = QualificationCase("ddl", "Verify ordered DDL and DML")
        let child = QualificationCase("rename", "RENAME removes the old table name")
        do {
            try reporter.run(parent) {
                try reporter.run(child) { throw LabError("old table remains") }
            }
            XCTFail("Expected the assertion to fail")
        } catch {
            let failure = reporter.fail(error)
            XCTAssertTrue(String(describing: failure).contains(child.description))
            XCTAssertTrue(String(describing: failure).contains("old table remains"))
        }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cases.json"))) as! [[String: Any]]
        XCTAssertEqual(saved.compactMap { $0["status"] as? String }, ["failed", "failed"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(saved[0]["seconds"] as? Double),
                                    try XCTUnwrap(saved[1]["seconds"] as? Double))
        XCTAssertEqual(saved[1]["parent_id"] as? String, "ddl")
        XCTAssertEqual(saved[1]["source_file"] as? String, child.file)
        XCTAssertEqual(saved[1]["source_line"] as? UInt, child.line)
        XCTAssertEqual(saved[1]["error"] as? String, "old table remains")
        XCTAssertFalse(messages.contains { $0.hasPrefix("passed") })
        XCTAssertTrue(messages.contains("failed " + child.description + ": old table remains"))
    }
    func testNamedAssertionRetainsFailureAndNeverPublishesAPass() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let reporter = QualificationReporter(output: output) { _ in }
        try reporter.begin(QualificationCase("case", "Named assertion failure"))
        XCTAssertThrowsError(try reporter.assertion("schema-effects", evidence: "assertions/schema.json") {
            try require(false, "deliberately wrong expected schema")
            return ["unused": true]
        })
        let assertions = reporter.results[0]["assertions"] as! [[String: Any]]
        XCTAssertEqual(assertions[0]["status"] as? String, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("assertions/schema.json").path))
    }
}
