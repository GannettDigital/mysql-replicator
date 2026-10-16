import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLSyntaxTests: XCTestCase {
  func testSourceByteRangesAndUnicodeIdentity() throws {
    let sql = Data("ALTER /* keep */ TABLE `café`.`表` ADD `élève` INT".utf8)
    let tokens = try SQLLexer.lex(sql)
    let table = try XCTUnwrap(tokens.first { $0.text == "表" })
    XCTAssertEqual(String(decoding: sql[try XCTUnwrap(table.range)], as: UTF8.self), "`表`")
    XCTAssertNotEqual(SQLToken(text: "é"), SQLToken(text: "e\u{301}"))
    XCTAssertEqual(SQLToken(text: "ſelect").keyword, "")
    XCTAssertEqual(SQLToken(text: "select").keyword, "SELECT")
  }

  func testModesAndMetadataComments() throws {
    XCTAssertTrue(try SQLLexer.lex(Data("\"column\"".utf8), sqlMode: 4)[0].identifier)
    XCTAssertEqual(try SQLLexer.lex(Data("\"value\"".utf8))[0].literal, "value")
    XCTAssertEqual(try SQLLexer.lex(Data("'a\\nb'".utf8))[0].literal, "a\nb")
    XCTAssertEqual(try SQLLexer.lex(Data("'a\\nb'".utf8), sqlMode: 1 << 20)[0].literal, "a\\nb")
    let source = Data("KEY x(v) /*!80000 INVISIBLE */".utf8)
    XCTAssertThrowsError(try SQLLexer.lex(source))
    let metadata = try SQLLexer.lex(source, nativeMetadata: true)
    let invisible = try XCTUnwrap(metadata.last)
    XCTAssertEqual(
      String(decoding: source[try XCTUnwrap(invisible.range)], as: UTF8.self), "INVISIBLE")
  }

  func testShiftJISTrailByteDoesNotEscapeQuote() throws {
    let source = Data([39, 0x95, 0x5c, 39])
    let tokens = try SQLLexer.lex(source, characterSet: "sjis") { bytes, _ in
      XCTAssertEqual(bytes, Data([0x95, 0x5c]))
      return SQLDecodedText(text: "表", bytes: bytes)
    }
    XCTAssertEqual(tokens[0].literal, "表")
    XCTAssertEqual(tokens[0].range, 0..<4)
  }

  func testTypedExpressionPrecedenceAndCompleteInput() throws {
    let value = try SQLExpression.parse(SQLLexer.lex(Data("a + b * 2".utf8)))
    guard
      case .binary("+", .identifier(let a), .binary("*", .identifier(let b), .number("2"))) = value
    else {
      return XCTFail("Expression must retain multiplication precedence")
    }
    XCTAssertEqual(a.text, "a")
    XCTAssertEqual(b.text, "b")
    XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(Data("a; DROP TABLE t".utf8))))
    XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(Data("abs(".utf8))))
  }

  func testSyntaxDoesNotDecideTargetFunctionEligibility() throws {
    let value = try SQLExpression.parse(SQLLexer.lex(Data("custom_function(a)".utf8)))
    guard case .call("custom_function", let arguments) = value,
      arguments.count == 1, case .identifier = arguments[0]
    else {
      return XCTFail("Syntax must preserve the call for target validation")
    }
  }

  func testLimitsAndErrorLocation() throws {
    let nested = Data(
      (String(repeating: "(", count: 150) + "a" + String(repeating: ")", count: 150)).utf8)
    XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(nested))) { error in
      XCTAssertNotNil((error as? SQLSyntaxError)?.range)
    }
    XCTAssertThrowsError(try SQLLexer.lex(Data(repeating: 32, count: 65_537)))
    XCTAssertThrowsError(try SQLLexer.lex(Data("'unterminated".utf8)))
    XCTAssertThrowsError(try SQLLexer.lex(Data("/* unterminated".utf8)))
  }
}
