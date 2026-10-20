import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class IncludeFilterTests: XCTestCase {
    func testNativeWildcardPrecedenceAndDefaultDecision() throws {
        let f = try TableFilter(["app.audit"], including: ["app.%"])
        XCTAssertFalse(f.ignores(database: "app", table: "audit"))
        XCTAssertTrue(f.ignores(database: "other", table: "t"))
        XCTAssertFalse(f.ignores(database: "app"))
        XCTAssertTrue(try TableFilter(including: ["app.t"]).ignores(database: "app"))
        XCTAssertFalse(
            try TableFilter(including: ["APP.T"], lowerCaseTableNames: 1).ignores(database: "app", table: "t"))
        XCTAssertFalse(try TableFilter(including: [#"app.a\_b"#]).ignores(database: "app", table: "a_b"))
        XCTAssertThrowsError(try TableFilter(including: ["bad"]))
    }
    func testDDLRejectsPartialDatabaseAndRenameScope() throws {
        let f = try TableFilter(including: ["app.t"])
        func query(_ sql: String) -> QueryControl {
            .init(database: "app", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())
        }
        XCTAssertThrowsError(try f.ignores(query("DROP DATABASE app")))
        XCTAssertThrowsError(try f.ignores(query("RENAME TABLE t TO excluded")))
        XCTAssertFalse(try f.ignores(query("CREATE TABLE t (id INT)")))
        XCTAssertTrue(try f.ignores(query("CREATE TABLE other (id INT)")))
        XCTAssertFalse(try TableFilter(["app.secret"], including: ["app.%"]).ignores(query("DROP DATABASE app")))
    }
}
