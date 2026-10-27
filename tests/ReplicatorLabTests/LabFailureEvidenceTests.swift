import Foundation
import XCTest

@testable import ReplicatorLabCore

final class LabFailureEvidenceTests: XCTestCase {
    func testCollectorUsesAnIndependentProcessAndTheSameStateVolume() {
        let command = LabFailureEvidence.command(image: "test-image", volume: "fixture-volume")
        XCTAssertEqual(command.first, "run")
        XCTAssertTrue(command.contains("--rm"))
        XCTAssertEqual(command[command.firstIndex(of: "--network")! + 1], "none")
        XCTAssertEqual(command[command.firstIndex(of: "--mount")! + 1], "type=volume,src=fixture-volume,dst=/evidence")
        XCTAssertEqual(
            Array(command.suffix(4)), ["test-image", "support-bundle", "--config", "/evidence/failure-support.yaml"])
    }

    func testAssertionFailureIsNamedAndBundlePathIsPrintedAndSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var logs: [String] = []
        let reporter = QualificationReporter(output: root) { logs.append($0) }
        try reporter.begin(.init("modify", "MODIFY pilot"))
        do {
            try reporter.assertion("row-values", evidence: "assertions/rows.json") {
                throw LabError("wrong target value")
            }
            XCTFail("expected failure")
        } catch {
            let failure = reporter.fail(error)
            XCTAssertTrue(String(describing: failure).contains("assertion row-values: wrong target value"))
            let record = LabFailureEvidence.collect(
                failure: String(describing: failure), output: root, cases: reporter.results,
                capture: { input in
                    XCTAssertTrue((input["error"] as? String ?? "").contains("wrong target value"))
                    return root.appendingPathComponent("support-bundles/test")
                }, log: { logs.append($0) })
            XCTAssertEqual((record["supportBundle"] as? [String: String])?["status"], "created")
        }
        XCTAssertTrue(logs.contains { $0.hasPrefix("Support bundle: ") && $0.contains("support-bundles/test") })
        let saved =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("harness-failure.json"))) as! [String: Any]
        XCTAssertTrue((saved["error"] as? String ?? "").contains("assertion row-values"))
        XCTAssertEqual((saved["cases"] as? [[String: Any]])?.first?["status"] as? String, "failed")
    }

    func testCollectionErrorDoesNotReplaceOriginalFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var logs: [String] = []
        let record = LabFailureEvidence.collect(
            failure: "original mismatch", output: root, cases: [],
            capture: { _ in
                throw LabError("state has an active writer")
            }, log: { logs.append($0) })
        XCTAssertEqual(record["error"] as? String, "original mismatch")
        XCTAssertEqual((record["supportBundle"] as? [String: String])?["status"], "failed")
        XCTAssertTrue(logs.contains { $0.contains("Support bundle collection failed: state has an active writer") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("harness-failure.json").path))
    }
}
