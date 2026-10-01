import XCTest
@testable import ReplicatorLabCore

final class SuiteSelectionTests: XCTestCase {
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
