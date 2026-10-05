import XCTest
@testable import ReplicatorLabCore

final class SuiteSelectionTests: XCTestCase {
    func testCoverageIsOptInAndIndependentOfFixtureSelection() throws {
        XCTAssertFalse(try SuiteSelection(arguments: [], ddl: true).codeCoverage)
        let selection = try SuiteSelection(arguments: ["--coverage", "--skip-build", "--positioning", "gtid", "--slice", "basic"], ddl: false)
        XCTAssertTrue(selection.codeCoverage)
        XCTAssertFalse(selection.build)
        XCTAssertEqual(selection.modes, ["gtid"])
        XCTAssertEqual(selection.slice, "basic")
    }
    func testDMLMatrixSelectsWholeDependentPhasesAndRejectsUnknownCases() throws {
        let selected=try SuiteSelection(arguments:["--case","matrix-decimal","--positioning","gtid"],ddl:false)
        XCTAssertEqual(selected.slice,"matrix")
        XCTAssertTrue(selected.selects("matrix-decimal")); XCTAssertFalse(selected.selects("matrix-values"))
        XCTAssertThrowsError(try SuiteSelection(arguments:["--case","matrix-unknown"],ddl:false))
        let extended = try SuiteSelection(arguments:["--slice","extended","--positioning","gtid"],ddl:false)
        XCTAssertTrue(extended.includes("extended")); XCTAssertFalse(extended.includes("matrix"))
        XCTAssertTrue(try SuiteSelection(arguments:[],ddl:false).includes("extended"))
        XCTAssertThrowsError(try SuiteSelection(arguments:["--slice","extended","--positioning","file-position"],ddl:false))
        XCTAssertEqual(try DMLCompatibilityCases.transactionCount("a:1-3:5,b:9-10"),6)
        XCTAssertEqual(try DMLCompatibilityCases.transactionCount(""),0)
    }
    func testDefaultsKeepBothFullProfilesAndInvalidSelectionsFailBeforeDocker() throws {
        let all = try SuiteSelection(arguments: [], ddl: true)
        XCTAssertEqual(all.modes, ["file-position", "gtid"])
        XCTAssertTrue(all.includes("ordered")); XCTAssertTrue(all.includes("modify-index"))
        for args in [["--case", "typo"], ["--positioning", "typo"], ["--slice", "unknown"], ["--case"], ["--slice", "database", "--case", "ddl-index-create"]] {
            XCTAssertThrowsError(try SuiteSelection(arguments: args, ddl: true))
        }
        XCTAssertThrowsError(try SuiteSelection(arguments: ["--slice", "modify-index"], ddl: false))
    }
    func testIndependentSelectionIncludesOnlyItsRequiredFixture() throws {
        let selected = try SuiteSelection(arguments: ["--case", "ddl-index-resume", "--positioning", "gtid", "--skip-build"], ddl: true)
        XCTAssertFalse(selected.build); XCTAssertEqual(selected.modes, ["gtid"])
        XCTAssertTrue(selected.selects("ddl-index-create")); XCTAssertTrue(selected.selects("ddl-index-resume"))
        XCTAssertFalse(selected.selects("ddl-index-timeout")); XCTAssertFalse(selected.includes("ordered"))
        let create = try SuiteSelection(arguments: ["--case", "ddl-index-create"], ddl: true)
        XCTAssertFalse(create.selects("ddl-index-resume"))
    }
}
