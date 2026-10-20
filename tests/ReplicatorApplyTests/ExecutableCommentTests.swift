import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ExecutableCommentTests: XCTestCase {
    func query(_ sql: String) -> QueryControl {
        .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())
    }
    func testTargetControlsSchemaPredictionWithoutChangingSQL() throws {
        let original = query("CREATE TABLE t(id INT /*!80400 , newer INT */)")
        for (profile, version, names): (ReplicationProfile, Int, [String]) in [
            (.mysql84To57MyISAM, 50742, ["id"]), (.mysql57To84InnoDB, 80408, ["id", "newer"]),
        ] {
            guard
                case .create(let table, _) = try DDLStatement.parse(original, profile: profile, targetVersion: version)
            else { return XCTFail("missing table") }
            XCTAssertEqual(table.columns.map(\.name), names)
        }
        XCTAssertEqual(String(decoding: original.sql, as: UTF8.self), "CREATE TABLE t(id INT /*!80400 , newer INT */)")
        XCTAssertEqual(
            try DDLStatement.parse(query("/*!80400 CREATE TABLE t(id INT) */"), targetVersion: 50742),
            .versionCommentNoop)
        XCTAssertThrowsError(try DDLStatement.parse(query("/* ordinary */")))
        // The lower target ignores this attribute instead of rejecting its active syntax.
        XCTAssertNoThrow(
            try DDLStatement.parse(
                query("CREATE TABLE t(id INT, KEY k(id) /*!80000 INVISIBLE */)"), targetVersion: 50742))
    }
    func testPoliciesAndFiltersUseTheSameTargetView() throws {
        let event = query("/*!80400 CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1 */")
        let low = try LoggedDDL.parsingView(event, targetVersion: 50742)
        XCTAssertFalse(try TableFilter(["excluded.%"]).ignores(low))
        XCTAssertNil(try DDLPolicy().skippedQuery(event, profile: .mysql84To57MyISAM, targetVersion: 50742))
        XCTAssertThrowsError(try DDLPolicy().skippedQuery(event, profile: .mysql57To84InnoDB, targetVersion: 80408))
        let trigger = query("/*!50700 DROP TRIGGER tr */")
        XCTAssertEqual(
            try DDLPolicy().skippedQuery(trigger, profile: .mysql84To57MyISAM, targetVersion: 50742)?.sql,
            String(decoding: trigger.sql, as: UTF8.self))
        let excluded = query("/*!50700 CREATE TABLE excluded.t(id INT) */")
        XCTAssertTrue(try TableFilter(["excluded.%"]).ignores(LoggedDDL.parsingView(excluded, targetVersion: 50742)))
    }
    func testCompatibilityEditsKeepWrapperAndLiteralBytes() throws {
        let original = query(
            "/*!50700 CREATE TABLE t(id INT, n VARCHAR(30) DEFAULT '/*! keep */') COLLATE=utf8mb4_0900_ai_ci */")
        let view = try LoggedDDL.parsingView(original, targetVersion: 50742)
        var parser = try DDLParser(query: view)
        parser.compatibility = try JSONDecoder().decode(
            CompatibilityPolicy.self, from: Data(#"{"collations":{"utf8mb4_0900_ai_ci":"utf8mb4_bin"}}"#.utf8))
        _ = try parser.parse()
        let output = parser.translatedSQL(original.sql)
        XCTAssertTrue(output.hasPrefix("/*!50700 CREATE"))
        XCTAssertTrue(output.hasSuffix("utf8mb4_bin */"))
        XCTAssertTrue(output.contains("'/*! keep */'"))
    }
    func testVersionParsing() throws {
        XCTAssertEqual(try LoggedDDL.versionID("5.7.42-log"), 50742)
        XCTAssertEqual(try LoggedDDL.versionID("8.4.8"), 80408)
        for bad in ["5.7", "5.7.x", "5.100.0", "-1.7.2"] { XCTAssertThrowsError(try LoggedDDL.versionID(bad)) }
    }
}
