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
        try reject({ $0["eligibility"]="excluded" },message:"tool gaps cannot be hidden")
        try reject({ $0["implementation"]="not_applicable" },message:"implementation gaps cannot be marked not applicable")
        try reject({ $0["classification"]="native_restriction" },message:"cannot count as positive support")
        try reject({ $0["classification"]="native_restriction"; $0["eligibility"]="excluded" },message:"needs a pinned source reference")
        try reject({ $0["qualification"]="passed" },message:"qualification")
        try reject({ $0["code_references"]=["../escape.swift"] },message:"unsafe catalog relative path")
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
