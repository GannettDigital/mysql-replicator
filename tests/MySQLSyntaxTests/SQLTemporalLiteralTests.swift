import Foundation
import XCTest
@testable import MySQLSyntax

final class SQLTemporalLiteralTests:XCTestCase {
    func testTypedTemporalLiterals() throws {
        for (name,type) in [("DATE","date"),("TIME","time"),("TIMESTAMP","datetime")] {
            let tokens=try SQLLexer.lex(Data((name+" '2026-01-01'").utf8))
            guard case .cast(.literal(let value),let actual)=try SQLExpression.parse(tokens) else {return XCTFail()}
            XCTAssertEqual(actual,type);XCTAssertEqual(value.literal,"2026-01-01")
        }
        XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(Data("DATE '2026-01-01' trailing".utf8))))
        guard case .identifier=try SQLExpression.parse(SQLLexer.lex(Data("`DATE`".utf8))) else {return XCTFail()}
    }
}
