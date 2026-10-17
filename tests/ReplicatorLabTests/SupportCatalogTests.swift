import Foundation
import XCTest
@testable import ReplicatorLabCore

final class SupportCatalogTests: XCTestCase {
    private var catalog: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DDLCoverage")
    }
    private func reject(_ change: (inout [String:Any]) -> Void, message: String) throws {
        let copy=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at:catalog,to:copy)
        defer { try? FileManager.default.removeItem(at:copy) }
        let file=copy.appendingPathComponent("support.json")
        var document=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        var rows=document["requirements"] as! [[String:Any]]
        change(&rows[0]);document["requirements"]=rows
        try JSONSerialization.data(withJSONObject:document).write(to:file)
        XCTAssertThrowsError(try DDLCoverage.load(directory:copy)) { error in
            XCTAssertTrue(String(describing:error).contains(message),String(describing:error))
        }
    }
    func testSupportUsesCurrentProfilesAndDoesNotClaimQualification() throws {
        let inventory=try DDLCoverage.load(directory:catalog)
        let report=DDLCoverage.report(inventory)["support"] as! [String:Any]
        let rows=report["requirements"] as! [[String:Any]]
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.flatMap { $0["profiles"] as! [String] }),Set(LabProfile.allCases.map(\.rawValue)))
        XCTAssertTrue(rows.allSatisfy { $0["qualification"] as? String == "unverified" })
        XCTAssertEqual((report["summary"] as! [String:Int])["qualified"],0)
        XCTAssertTrue(DDLCoverage.markdown(inventory).contains("## Support requirements"))
        let imported=try DDLCoverageEvidence.report(inventory,bundles:[])["support"] as! [String:Any]
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),
                       try JSONSerialization.data(withJSONObject:imported,options:.sortedKeys))
    }
    func testRejectsInvalidBindingsAndHiddenGaps() throws {
        try reject({ $0["profiles"]=["unknown"] },message:"unknown profile")
        try reject({ $0["profiles"]=["mysql57-to-mysql57-innodb"]; $0["variants"]=["position-minimal"] },message:"unsupported profile/variant")
        try reject({ $0["candidate_cases"]=["not-a-test"] },message:"unknown candidate case")
        try reject({ $0["eligibility"]="excluded" },message:"positive-support work cannot be hidden")
        try reject({ $0["implementation"]="not_applicable" },message:"implementation gaps cannot be marked not applicable")
        try reject({ $0["classification"]="native_restriction" },message:"cannot count as positive support")
        try reject({ $0["classification"]="native_restriction"; $0["eligibility"]="excluded" },message:"needs a pinned source reference")
        try reject({ $0["classification"]="tool_gap"; $0["implementation"]="implemented" },message:"tool gap needs a missing or subset implementation")
        try reject({ $0["qualification"]="passed" },message:"qualification")
        try reject({ $0["code_references"]=["../escape.swift"] },message:"unsafe catalog relative path")
    }
    func testReportSeparatesUnsupportedPathsFromIncompleteTests() throws {
        let inventory=try DDLCoverage.load(directory:catalog)
        let report=inventory.support.report(upstream:inventory.upstream)
        let rows=report["requirements"] as! [[String:Any]]
        let summary=report["summary"] as! [String:Int]
        let gaps=rows.filter{$0["classification"] as? String == "tool_gap"}
        let untested=rows.filter{$0["classification"] as? String == "untested"}
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertFalse(untested.isEmpty)
        XCTAssertEqual(summary["confirmed_tool_gaps"],gaps.count)
        XCTAssertEqual(summary["qualification_gaps"],untested.count)
        XCTAssertTrue(untested.contains{$0["implementation"] as? String == "implemented"})
        for id in ["ddl.partial-source-errors","names.case-settings"] {
            XCTAssertTrue(gaps.contains{$0["id"] as? String == id},id)
        }
        for id in ["ddl.executable-comments","ddl.partition-column-renames","ddl.simultaneous-column-renames","ddl.generated-expressions"] {
            XCTAssertTrue(untested.contains{$0["id"] as? String == id},id)
        }
        let text=inventory.support.markdown
        XCTAssertTrue(text.contains("selected cases can already pass"))
        XCTAssertTrue(text.contains("not feature-support percentages"))
        XCTAssertEqual(summary["qualified"],0)
    }
    func testRequirementsReferenceExistingImplementationFiles() throws {
        let inventory=try DDLCoverage.load(directory:catalog)
        let root=catalog.deletingLastPathComponent().deletingLastPathComponent()
        for requirement in inventory.support.requirements {
            for path in requirement.codeReferences {
                XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path),requirement.id+": "+path)
            }
        }
    }
}
