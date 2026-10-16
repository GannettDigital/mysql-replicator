import XCTest

@testable import ReplicatorApply

final class SQLTextByteArrayTests: XCTestCase {
    func testArrayComparisonRetainsUnicodeSpelling() {
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        // Swift considers these strings equal. MySQL names retain their bytes.
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(SQLTextBytes.equal([composed], [decomposed]))
        XCTAssertTrue(SQLTextBytes.equal([decomposed], [decomposed]))
    }

    func testArrayComparisonRetainsOrderLengthAndEmptyValues() {
        XCTAssertTrue(SQLTextBytes.equal([], []))
        XCTAssertTrue(SQLTextBytes.equal(["a", ""], ["a", ""]))
        XCTAssertFalse(SQLTextBytes.equal(["a", "b"], ["b", "a"]))
        XCTAssertFalse(SQLTextBytes.equal(["a"], ["a", ""]))
        XCTAssertFalse(SQLTextBytes.equal([], [""]))
    }
}
