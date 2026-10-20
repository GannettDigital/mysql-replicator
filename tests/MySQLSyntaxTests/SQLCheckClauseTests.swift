import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLCheckClauseTests: XCTestCase {
    func testNestedOpaqueExpressionAndSourceRange() throws {
        let sql = "CHECK (unknown_fn(v, '),;CHECK(') > 0 /* ) */ AND (id IN(1,2))) , next"
        let tokens = try SQLLexer.lex(Data(sql.utf8))
        let clause = try SQLCheckClause.parsePrefix(tokens[...])
        XCTAssertEqual(tokens[clause.consumed].keyword, ",")
        XCTAssertEqual(clause.expression.first?.text, "unknown_fn")
        XCTAssertEqual(clause.range, 0..<(sql.range(of: " , next")!.lowerBound.utf16Offset(in: sql)))
        var withoutRanges = tokens
        for i in withoutRanges.indices { withoutRanges[i].range = nil }
        XCTAssertNil(try SQLCheckClause.parsePrefix(withoutRanges[...]).range)
    }
    func testMissingBodyUnbalancedAndAdditionalStatement() throws {
        for sql in [
            "", "CHECK", "CHECK x", "CHECK ()", "CHECK (),x", "CHECK ((1)", "CHECK (1; DROP TABLE t)",
            "`CHECK` (1)",
        ] {
            XCTAssertThrowsError(try SQLCheckClause.parsePrefix(SQLLexer.lex(Data(sql.utf8))[...]), sql)
        }
    }
}
