import XCTest
import Foundation
@testable import ReplicatorLabCore

final class LabSQLNameTests:XCTestCase {
    func testComparisonKeepsCanonicalFormsAndQuoting() {
        XCTAssertFalse(LabSQLName.equal("é","e\u{0301}"))
        XCTAssertEqual(Set([Data("é".utf8),Data("e\u{0301}".utf8)]).count,2)
        XCTAssertEqual(LabSQLName.quote("中`名"),"`中``名`")
        XCTAssertEqual(LabSQLName.literal("e\u{0301}'"),"CONVERT(0x65CC8127 USING utf8mb4)")
    }
}
