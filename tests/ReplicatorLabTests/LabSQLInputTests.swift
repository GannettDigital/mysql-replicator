import XCTest

@testable import ReplicatorLabCore

final class LabSQLInputTests: XCTestCase {
    func testScriptRetainsClientDirectivesAndExactUnicodeBytes() throws {
        let sql =
            "SELECT 'cafe\u{0301}';;\nDELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$\nDELIMITER ;"
        let input = try LabSQLInput(sql, resetGTID: true, script: true)
        XCTAssertEqual(input.arguments, [])
        XCTAssertEqual(input.bytes, Data(("SET @@SESSION.GTID_NEXT = 'AUTOMATIC';\n" + sql + "\n").utf8))
    }
    func testRoutineRequestRetainsBodyAndSeparatesGTIDReset() throws {
        let sql = "CREATE PROCEDURE p() BEGIN SELECT ';'; SELECT 2; END"
        let input = try LabSQLInput(sql, resetGTID: true, script: false, delimiter: "_end_")
        XCTAssertEqual(input.arguments, ["--delimiter=_end_"])
        XCTAssertEqual(input.bytes, Data(("SET @@SESSION.GTID_NEXT = 'AUTOMATIC'\n_end_\n" + sql + "\n_end_\n").utf8))
    }
    func testSourceRequestAndVerticalOutput() throws {
        let input = try LabSQLInput("SHOW REPLICA STATUS\\G", resetGTID: false, script: false, delimiter: "_end_")
        XCTAssertEqual(input.arguments, ["--delimiter=_end_", "--vertical"])
        XCTAssertEqual(input.bytes, Data("SHOW REPLICA STATUS\n_end_\n".utf8))
        XCTAssertThrowsError(try LabSQLInput("SELECT '_end_'", resetGTID: false, script: false, delimiter: "_end_"))
    }
}
