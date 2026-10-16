import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLLexerTests: XCTestCase {
  func testQuotesEscapesAndComments() throws {
    let cases: [(String, [String])] = [
      (" \t\r\n", []), ("# note\nSELECT", ["SELECT"]),
      ("-- note\r\nSELECT", ["SELECT"]), ("--x", ["-", "-", "x"]),
      ("/**/a/* keep */b", ["a", "b"]),
      ("`a``b` 'a''b' \"a\"\"b\"", ["a`b", "'a''b'", "'a\"b'"]),
      (
        "(a),b.c;=+-*/%@< >!|&^~:?",
        [
          "(", "a", ")", ",", "b", ".", "c", ";", "=", "+", "-", "*", "/", "%", "@", "<", ">", "!",
          "|", "&", "^", "~", ":", "?",
        ]
      ),
      (
        "<= >= != <> << >> || && := -> ->>",
        ["<=", ">=", "!=", "<>", "<<", ">>", "||", "&&", ":=", "->", "->>"]
      ),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(try SQLLexer.lex(Data(input.utf8)).map(\.text), expected, input)
    }
    let escapes = try SQLLexer.lex(Data("'\\0\\b\\n\\r\\t\\Z\\%\\_\\q\\\\'".utf8))
    XCTAssertEqual(escapes[0].literal, "\0\u{8}\n\r\t\u{1A}\\%\\_q\\")
    XCTAssertEqual(try SQLLexer.lex(Data("`a\\b`".utf8))[0].text, "a\\b")
  }

  func testInvalidInputAndLimits() throws {
    for input in ["/*", "/*!80000 SELECT 1 */", "'", "'abc\\", "`abc", "[", "\u{1}"] {
      XCTAssertThrowsError(try SQLLexer.lex(Data(input.utf8)), input)
    }
    XCTAssertThrowsError(try SQLLexer.lex(Data([0xff])))
    XCTAssertEqual(try SQLLexer.lex(Data(repeating: 32, count: 65536)), [])
    XCTAssertThrowsError(try SQLLexer.lex(Data(String(repeating: "a ", count: 16385).utf8)))
    XCTAssertThrowsError(
      try SQLLexer.lex(
        Data((String(repeating: "a ", count: 16384) + "/*!80000 b */").utf8), nativeMetadata: true))
  }

  func testConvertedTokenBytesAndDecoderFailure() throws {
    let bytes = Data([96, 0xe9, 96, 32, 39, 0xe9, 39])
    var calls: [Bool] = []
    let tokens = try SQLLexer.lex(bytes, characterSet: "latin1") { value, identifier in
      calls.append(identifier)
      XCTAssertEqual(value, Data([0xe9]))
      return SQLDecodedText(text: "é", bytes: identifier ? nil : value)
    }
    XCTAssertEqual(calls, [true, false])
    XCTAssertEqual(tokens[1].literalBytes, Data([0xe9]))
    enum ConversionFailure: Error { case failed }
    XCTAssertThrowsError(try SQLLexer.lex(bytes) { _, _ in throw ConversionFailure.failed }) {
      error in
      XCTAssertTrue(error is ConversionFailure)
    }
  }

  func testTokenEqualityUsesBytesButNotLocation() {
    let value = SQLToken(text: "x", literal: "é", literalBytes: Data([0xe9]), range: 0..<1)
    XCTAssertEqual(
      value, SQLToken(text: "x", literal: "é", literalBytes: Data([0xe9]), range: 2..<3))
    XCTAssertNotEqual(value, SQLToken(text: "x", literal: "e\u{301}", literalBytes: Data([0xe9])))
    XCTAssertNotEqual(value, SQLToken(text: "x", literal: "é"))
    XCTAssertNotEqual(
      value, SQLToken(text: "x", identifier: true, literal: "é", literalBytes: Data([0xe9])))
    XCTAssertEqual(SQLToken(text: "select", literal: "select").keyword, "")
  }

  func testNativeMultibyteBoundaries() {
    let cases: [(String, [UInt8], Int)] = [
      ("sjis", [0x81, 0x5c], 2), ("cp932", [0xe0, 0x80], 2), ("sjis", [0x81, 0x7f], 1),
      ("big5", [0xa1, 0x5c], 2), ("big5", [0xa1, 0xa1], 2), ("big5", [0xa0, 0x5c], 1),
      ("gbk", [0x81, 0x5c], 2), ("gbk", [0x81, 0x7f], 1), ("gbk", [0x80, 0x40], 1),
      ("gb18030", [0x81, 0x30, 0x81, 0x30], 4), ("gb18030", [0x81, 0x30, 0x81], 1),
      ("gb18030", [0x81, 0x30, 0x81, 0x40], 1), ("latin1", [0xe9, 0x27], 1),
      ("sjis", [0x81], 1),
    ]
    for (charset, bytes, width) in cases {
      XCTAssertEqual(
        SQLClientEncoding.characterWidth(bytes, at: 0, charset: charset), width,
        charset + " \(bytes)")
    }
  }
}
