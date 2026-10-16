import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class AccountStatementSkipTests: XCTestCase {
    func testAccountGrantHasStableBeforeWriteSkipCode() throws {
        let query = QueryControl(
            database: "skip_poc", sql: Data("GRANT SELECT ON skip_poc.* TO 'skip_fixture'@'localhost'".utf8),
            errorCode: 0, statusVariables: Data())
        var policy = SkipErrorPolicy()
        policy.codes = [.unsupportedDDL]
        XCTAssertThrowsError(try DDLStatement.parse(query)) { error in
            XCTAssertEqual((error as? ApplyError)?.code, .unsupportedDDL)
            XCTAssertNotNil(policy.match(error, at: .beforeWrites))
            XCTAssertNil(policy.match(error, at: .rolledBack))
        }
    }
}
