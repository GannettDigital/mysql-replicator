import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLExpressionTests: XCTestCase {
  func testFlatAndNestedTreesStayBounded() throws {
    let flat = Array(repeating: "a", count: 200).joined(separator: "+")
    XCTAssertThrowsError(try parse(flat))
    XCTAssertNoThrow(try parse(Array(repeating: "a", count: 100).joined(separator: "+")))
    let nested = "(" + Array(repeating: "a", count: 80).joined(separator: "+") + ")"
    let combined = ([nested] + Array(repeating: "a", count: 80)).joined(separator: "+")
    XCTAssertThrowsError(try parse(combined))
  }

  private func parse(_ sql: String) throws -> SQLExpression {
    try SQLExpression.parse(SQLLexer.lex(Data(sql.utf8)))
  }

  func testAtomsAndFunctions() throws {
    XCTAssertEqual(try parse("12.34"), .number("12.34"))
    for word in ["NULL", "TRUE", "FALSE"] {
      XCTAssertEqual(try parse(word), .keyword(word.lowercased()))
    }
    for op in ["+", "-", "NOT", "~"] {
      guard case .prefix(let name, .number("2")) = try parse(op + " 2") else { return XCTFail(op) }
      XCTAssertEqual(name, op.lowercased())
    }
    guard case .call("concat", let args) = try parse("concat('a',abs(n),2)") else {
      return XCTFail()
    }
    XCTAssertEqual(args.count, 3)
    guard case .literal(let literal) = args[0] else { return XCTFail() }
    XCTAssertEqual(literal.literal, "a")
    XCTAssertEqual(try parse("custom()"), .call("custom", []))
    guard case .introduced("_latin1", .literal) = try parse("_latin1'café'") else {
      return XCTFail()
    }
  }

  func testGroupingAssociativityAndOperators() throws {
    guard case .binary("-", .binary("-", _, _), _) = try parse("a-b-c") else { return XCTFail() }
    guard case .binary("*", .binary("+", _, _), _) = try parse("(a+b)*c") else { return XCTFail() }
    guard case .binary("or", _, .binary("and", _, _)) = try parse("a OR b AND c") else {
      return XCTFail()
    }
    for op in [
      "=", "!=", "<>", "<", ">", "<=", ">=", "+", "-", "*", "/", "DIV", "%", "MOD", "->", "->>",
    ] {
      guard case .binary(let actual, _, _) = try parse("a " + op + " b") else { return XCTFail(op) }
      XCTAssertEqual(actual, op.lowercased())
    }
    guard case .collate(.identifier, "utf8mb4_bin") = try parse("v COLLATE utf8mb4_bin") else {
      return XCTFail()
    }
  }

  func testCastsPreserveSyntaxForTheMetadataAdapter() throws {
    for (sql, type) in [
      ("CAST(v AS CHAR(10) CHARACTER SET utf8mb4)", "char(10) charset utf8mb4"),
      ("CAST(v AS CHAR CHARSET latin1)", "char charset latin1"),
      ("CAST(v AS DECIMAL(10,2))", "decimal(10,2)"),
      ("CAST(v AS UNSIGNED INTEGER)", "unsigned"),
      ("CAST(v AS SIGNED)", "signed"), ("CAST(v AS JSON)", "json"),
    ] {
      guard case .cast(.identifier, let actual) = try parse(sql) else { return XCTFail(sql) }
      XCTAssertEqual(actual, type)
    }
  }

  func testMalformedExpressionsFailWithoutRecovery() {
    for sql in [
      "", "(", "()", "a+", "a b", "a;", ",", "f(a,)", "f(a b)", "f(",
      "CAST(a)", "CAST(a AS)", "CAST(a AS madeup)", "CAST(a AS CHAR(x))",
      "CAST(a AS DECIMAL(2,))", "CAST(a AS CHAR CHARACTER latin1)",
      "CAST(a AS CHAR CHARSET)", "a COLLATE", "a COLLATE 'utf8mb4_bin'",
    ] {
      XCTAssertThrowsError(try parse(sql), sql) { error in
        XCTAssertTrue(error is SQLSyntaxError, sql)
        XCTAssertFalse(String(describing: error).isEmpty)
      }
    }
    XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(Data("a".utf8)), maximumDepth: 0))
  }
}
