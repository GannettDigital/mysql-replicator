import XCTest
@testable import ReplicatorLabCore

final class DDLObservationTests:XCTestCase {
    func testIndexFieldsRetainEmptyCommentAndIgnoreVersionSpecificColumns() throws {
        let check=DDLCompatibilityCases.Check("SHOW INDEX","by_v\tBTREE\t",fields:[2,10,11],myISAMExpected:"by_v\tBTREE\tdisabled")
        let common="t\t1\tby_v\t1\tv\tA\t2\tNULL\tNULL\tYES\tBTREE\t"
        XCTAssertEqual(try check.observation(common+"\t"),check.expected(engine:"InnoDB"))
        XCTAssertEqual(try check.observation(common+"\tYES\tNULL"),check.expected(engine:"InnoDB"))
        XCTAssertEqual(try check.observation(common+"disabled\t"),check.expected(engine:"MyISAM"))
        XCTAssertThrowsError(try check.observation("missing\tfields"))
    }
    func testUnprojectedChecksRetainRawText() throws {
        let check=DDLCompatibilityCases.Check("SELECT value"," a\tb\n c\td")
        XCTAssertEqual(try check.observation(check.expected),check.expected(engine:"MyISAM"))
    }
}
