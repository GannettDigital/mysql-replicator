import XCTest

@testable import ReplicatorApply

final class TargetQueryPurposeTests: XCTestCase {
    func testQueryFamiliesDoNotIncludeSQLOrValues() {
        for (sql, mutation, expected) in [
            ("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_NAME='secret'", false, "schema.columns"),
            ("SELECT * FROM information_schema.STATISTICS", false, "schema.statistics"),
            ("SELECT * FROM information_schema.USER_PRIVILEGES", false, "schema.user_privileges"),
            ("SELECT * FROM information_schema.COLLATIONS", false, "schema.collations"),
            ("SET SESSION sql_mode='secret'", false, "session_setup"),
            ("COMMIT", false, "transaction_control"),
            ("INSERT INTO secret VALUES ('private')", true, "target_write"),
            ("BINLOG 'private-bytes'", true, "target_write"),
            ("SHOW SLAVE STATUS", false, "target_metadata"),
        ] {
            XCTAssertEqual(TargetQueryPurpose.classify(sql, mutation: mutation), expected)
        }
    }
}
