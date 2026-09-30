import Foundation
import XCTest
@testable import ReplicatorLabCore

final class DDLCoverageEvidenceTests: XCTestCase {
    private var inventory: DDLCoverage.Inventory {
        get throws {
            try DDLCoverage.load(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DDLCoverage"))
        }
    }
    private func matchingCases() -> [[String: Any]] {
        let selected = Set(DDLCoverageCases.evidenceContracts.values.flatMap { $0.values.flatMap { $0 } })
        return [["id": "ddl", "status": "passed"]] + selected.sorted().map { id in
            ["id": id, "status": "passed", "assertions": [["id": DDLCoverageCases.assertion(for: id)!, "status": "passed", "evidence": "assertions/" + id + ".json"]]]
        }
    }
    func testNamedAssertionsIncreasePartialCoverageWithoutQualifyingOtherObligations() throws {
        let inventory = try inventory
        let before = try DDLCoverageEvidence.report(inventory, bundles: [])
        let bundles = DDLCoverageCases.swiftProfiles.map { DDLCoverageEvidence.Bundle(profile: $0, stale: false, passed: true, cases: matchingCases(), origin: "fixture") }
        let after = try DDLCoverageEvidence.report(inventory, bundles: bundles)
        XCTAssertEqual((before["assertion_summary"] as! [String: Int])["passed"], 0)
        XCTAssertEqual((after["assertion_summary"] as! [String: Int])["passed"], 44)
        XCTAssertEqual((after["assertion_summary"] as! [String: Int])["partial_scenario_profiles"], 22)
        XCTAssertEqual((after["assertion_summary"] as! [String: Int])["verified_scenario_profiles"], 0)
        let rows = after["scenarios"] as! [[String: Any]]
        XCTAssertEqual(rows.filter { $0["qualification"] as? String == "partial" }.count, 11)
        XCTAssertThrowsError(try DDLCoverageEvidence.report(inventory, bundles: [bundles[0], bundles[0]]))
    }
    func testMissingAssertionAndParentOrCleanupFailureCannotBecomeCoverage() throws {
        let scenario = try XCTUnwrap(inventory.catalog.scenarios.first { $0.id == "ddl.table.truncate.empty" })
        let profile = scenario.requiredProfiles[0]
        var cases = matchingCases()
        let index = cases.firstIndex { $0["id"] as? String == "update-after-empty-truncate" }!
        cases[index]["assertions"] = []
        let incomplete = DDLCoverageEvidence.evaluate(scenario, profile: profile, bundle: .init(profile: profile, stale: false, passed: true, cases: cases, origin: "fixture"))
        XCTAssertEqual(incomplete["passed_assertions"] as? [String], ["schema-effects"])
        for cleanupPassed in [true, false] {
            cases[0]["status"] = cleanupPassed ? "failed" : "passed"
            let failed = DDLCoverageEvidence.evaluate(scenario, profile: profile, bundle: .init(profile: profile, stale: false, passed: cleanupPassed, cases: cases, origin: "fixture"))
            XCTAssertEqual(failed["qualification"] as? String, "failed")
            XCTAssertEqual(failed["passed_assertions"] as? [String], [])
        }
        let stale = DDLCoverageEvidence.evaluate(scenario, profile: profile, bundle: .init(profile: profile, stale: true, passed: true, cases: matchingCases(), origin: "fixture"))
        XCTAssertEqual(stale["qualification"] as? String, "stale")
        XCTAssertEqual(stale["passed_assertions"] as? [String], [])
    }
    func testChecksummedBundleRejectsTamperingMissingFilesAndPathEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddl-evidence-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = ["Sources/example.swift": String(repeating: "a", count: 64)]
        let contracts = ["catalog": String(repeating: "b", count: 64)]
        let cases = matchingCases()
        try writeJSON(cases, to: root.appendingPathComponent("cases.json"))
        try writeJSON(["result": "passed", "cleanup": "passed"], to: root.appendingPathComponent("result.json"))
        let servers: [[String: Any]] = try inventory.profiles.profiles.first { $0.id == DDLCoverageCases.swiftProfiles[0] }!.servers.map { server in
            ["role": server.role, "version": server.version, "image": "sha256:" + String(repeating: "1", count: 64),
             "settings": Dictionary(uniqueKeysWithValues: server.settings.filter { $0.basis != "query_context" }.map { ($0.name, $0.value == "(empty)" ? "" : $0.value) })]
        }
        try writeJSON(["profile": DDLCoverageCases.swiftProfiles[0], "build_inputs_digest": DDLCoverageEvidence.digest(input), "servers": servers, "binary_sha256": String(repeating: "a", count: 64)], to: root.appendingPathComponent("coverage-runtime.json"))
        var paths = ["cases.json", "result.json", "coverage-runtime.json"]
        for test in cases {
            for assertion in test["assertions"] as? [[String: Any]] ?? [] {
                let path = assertion["evidence"] as! String
                try writeJSON(["observed": "fixture"], to: root.appendingPathComponent(path)); paths.append(path)
            }
        }
        var manifest: [String: Any] = ["schema_version": 1, "kind": "ddl_named_assertions_partial_v1", "suite": "ddl-suite", "profile": DDLCoverageCases.swiftProfiles[0], "inputs": input, "contract_hashes": contracts, "inputs_unchanged": true, "harness_binary_sha256": String(repeating: "c", count: 64), "artifact_hashes": try DDLCoverageEvidence.hashes(root: root, paths: paths)]
        let path = root.appendingPathComponent("coverage-evidence.json")
        try writeJSON(manifest, to: path)
        XCTAssertFalse(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: contracts, inventory: inventory).stale)
        XCTAssertTrue(try DDLCoverageEvidence.load(path, currentInputs: [:], contracts: contracts, inventory: inventory).stale)
        XCTAssertTrue(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: [:], inventory: inventory).stale)
        XCTAssertTrue(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: contracts, inventory: inventory, harnessDigest: "different").stale)
        try writeJSON(["result": "failed"], to: root.appendingPathComponent("result.json"))
        XCTAssertThrowsError(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: contracts, inventory: inventory))
        try FileManager.default.removeItem(at: root.appendingPathComponent("cases.json"))
        XCTAssertThrowsError(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: contracts, inventory: inventory))
        manifest["artifact_hashes"] = ["../escape": String(repeating: "a", count: 64), "cases.json": "unused", "result.json": "unused", "coverage-runtime.json": "unused"]
        try writeJSON(manifest, to: path)
        XCTAssertThrowsError(try DDLCoverageEvidence.load(path, currentInputs: input, contracts: contracts, inventory: inventory))
    }
}
