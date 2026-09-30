import Foundation
import XCTest
@testable import ReplicatorLabCore

final class DDLCoverageTests: XCTestCase {
    private var committed: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DDLCoverage")
    }
    private func edited(_ file: String = "catalog", _ mutate: (inout [String: Any]) -> Void, _ inspect: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ddl-catalog-" + UUID().uuidString)
        try FileManager.default.copyItem(at: committed, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(file + ".json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
        try inspect(directory)
    }
    private func rejects(_ expected: String, file: String = "catalog", _ mutate: (inout [String: Any]) -> Void) throws {
        try edited(file, mutate) { directory in
            XCTAssertThrowsError(try DDLCoverage.load(directory: directory)) { error in
                XCTAssertTrue(String(describing: error).contains(expected), "Unexpected diagnostic: \(error)")
            }
        }
    }
    private func firstScenario(_ object: inout [String: Any], _ mutate: (inout [String: Any]) -> Void) {
        var rows = object["scenarios"] as! [[String: Any]]
        mutate(&rows[0]); object["scenarios"] = rows
    }
    func testCommittedInventoryWorksWithoutUpstreamOrArtifacts() throws {
        try edited("catalog", { _ in }) { directory in
            let inventory = try DDLCoverage.load(directory: directory)
            XCTAssertEqual(inventory.catalog.scenarios.count, 55)
            XCTAssertEqual(inventory.catalog.families.map(\.reviewState), Array(repeating: "partial", count: 6))
            XCTAssertEqual(DDLCoverageCases.registry.count, 46)
            let report = DDLCoverage.report(inventory)
            let rows = report["scenarios"] as! [[String: Any]]
            XCTAssertTrue(rows.allSatisfy { $0["qualification"] as? String == "unverified" })
            XCTAssertEqual(report["evidence_status"] as? String, "not_loaded")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".upstream").path))
        }
    }
    func testUnknownNestedFieldsAndSchemaVersionsFailClosed() throws {
        try rejects("unknown fields") { object in
            self.firstScenario(&object) { $0["covered"] = true }
        }
        try rejects("invalid enum") { $0["schema_version"] = 2 }
        try rejects("expected integer") { $0["schema_version"] = true }
        try rejects("unknown fields", file: "profiles") { object in
            var profiles = object["profiles"] as! [[String: Any]]
            profiles[0]["row_metdata"] = "FULL"; object["profiles"] = profiles
        }
    }
    func testDuplicateAndDanglingIDsFail() throws {
        try rejects("duplicate scenario") { object in
            var rows = object["scenarios"] as! [[String: Any]]
            rows.append(rows[0]); object["scenarios"] = rows
        }
        try rejects("dangling case binding") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0]["case_ids"] = ["missing-case"]; row["bindings"] = bindings
            }
        }
        try rejects("dangling upstream reference") { object in
            self.firstScenario(&object) { $0["upstream_refs"] = [["id":"does-not-exist", "relationship":"related_reference", "note":"test"]] }
        }
        try rejects("unmapped registered cases") { $0["case_classifications"] = [] }
    }
    func testProfileAndExpectedOutcomeContradictionsFail() throws {
        try rejects("inapplicable profile") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0]["profiles"] = ["native.restricted"]; row["bindings"] = bindings
            }
        }
        try rejects("apply intent contradicts") { object in
            self.firstScenario(&object) { row in
                var expectations = row["expectations"] as! [[String: Any]]
                expectations[0]["swift57"] = ["outcome":"rejection", "diagnostic":"unsupported", "warnings":"none", "partial_effects":"none"]
                row["expectations"] = expectations
            }
        }
        try rejects("no source event") { object in
            self.firstScenario(&object) { row in
                var expectations = row["expectations"] as! [[String: Any]]
                var source = expectations[0]["source"] as! [String: Any]
                source["logging"] = "no_event"; expectations[0]["source"] = source; row["expectations"] = expectations
            }
        }
    }
    func testParentAndAssertionBindingsCannotBeInvented() throws {
        try rejects("completion group") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0].removeValue(forKey: "completion_case_id"); row["bindings"] = bindings
            }
        }
        try rejects("undeclared assertions") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0]["assertion_ids"] = ["invented-pass"]; row["bindings"] = bindings
            }
        }
        try rejects("out of execution order") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0]["case_ids"] = ["insert-binary", "create-local-engine"]; row["bindings"] = bindings
            }
        }
    }
    func testUnsafePathsAndFalseReviewCompletionFail() throws {
        try rejects("unsafe catalog relative path", file: "upstream") { object in
            var refs = object["references"] as! [[String: Any]]
            refs[0]["path"] = "../other.test"; object["references"] = refs
        }
        try rejects("unreviewed candidate") { object in
            var families = object["families"] as! [[String: Any]]
            families[0]["review_state"] = "reviewed_for_declared_scope"; families[0]["outstanding_questions"] = []
            object["families"] = families
        }
        for path in ["/tmp/x", "a//b", "a/../b", "a\\b", "https://host/x", "a/./b"] {
            XCTAssertThrowsError(try DDLCoverage.safePath(path))
        }
    }
    func testSchemaVocabularyErrorsAndSymlinkEscapesFailClosed() throws {
        XCTAssertThrowsError(try DDLCoverageSchema.validate("value", schema: ["type":"string", "minLength":"silently ignored?"]))
        XCTAssertThrowsError(try DDLCoverageSchema.validate("value", schema: ["type":"string", "unknownKeyword":true]))
        XCTAssertThrowsError(try DDLCoverageSchema.validate("value", schema: ["type":"string", "minimum":1]))
        try edited("catalog", { _ in }) { directory in
            let schema = directory.appendingPathComponent("schema/catalog.schema.json")
            try FileManager.default.removeItem(at: schema)
            try FileManager.default.createSymbolicLink(at: schema, withDestinationURL: committed.appendingPathComponent("schema/catalog.schema.json"))
            XCTAssertThrowsError(try DDLCoverage.load(directory: directory)) { error in
                XCTAssertTrue(String(describing: error).contains("escapes its directory"))
            }
        }
        try rejects("lacks executable evidence contract") { object in
            self.firstScenario(&object) { row in
                var bindings = row["bindings"] as! [[String: Any]]
                bindings[0]["assertion_ids"] = ["schema-effects"]; row["bindings"] = bindings
            }
        }
    }
    func testRegistryUsesTheActualExecutableScenarioDefinitions() throws {
        let registry = DDLCoverageCases.registry
        for change in DDLCoverageCases.changes {
            let entry = try XCTUnwrap(registry.first { $0.suite == "ddl-suite" && $0.test.id == change.test.id })
            XCTAssertEqual(entry.test.line, change.test.line)
            XCTAssertEqual(entry.test.name, change.test.name)
            XCTAssertEqual(entry.test.file, "Sources/ReplicatorLabCore/DDLCoverageCases.swift")
            XCTAssertEqual(entry.parent, "ddl")
        }
        XCTAssertEqual(Set(registry.map(\.key)).count, registry.count)
    }
    func testReportsAreDeterministicAndMissingImplementationStaysVisible() throws {
        let inventory = try DDLCoverage.load(directory: committed)
        let one = try JSONSerialization.data(withJSONObject: DDLCoverage.report(inventory), options: [.sortedKeys])
        let two = try JSONSerialization.data(withJSONObject: DDLCoverage.report(inventory), options: [.sortedKeys])
        XCTAssertEqual(one, two)
        let report = DDLCoverage.markdown(inventory)
        XCTAssertEqual(report, DDLCoverage.markdown(inventory))
        XCTAssertTrue(report.contains("ddl.table.create-if-not-exists.different"))
        XCTAssertTrue(report.contains("No evidence loaded"))
        XCTAssertTrue(report.contains("missing"))
        XCTAssertFalse(report.contains("| verified |"))
    }
    func testUnavailableEvidenceAndVerifyCommandsAreNotSilentlyAccepted() throws {
        let root = committed.deletingLastPathComponent().deletingLastPathComponent()
        for args in [["verify"], ["scan", "--unsupported"], ["report", "--evidence", "old-result.json"], ["check", "--format", "json"], ["report", "--format"]] {
            XCTAssertThrowsError(try DDLCoverage.run(root: root, arguments: args))
        }
    }
}
