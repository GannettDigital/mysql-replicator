import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLPredicateTests: XCTestCase {
    func parse(_ sql: String, mode: UInt64 = 0, depth: Int = 128) throws -> SQLExpression {
        try SQLExpression.parse(
            SQLLexer.lex(Data(sql.utf8), sqlMode: mode), sqlMode: mode, maximumDepth: depth)
    }
    func testCaseAndPredicatesKeepTypedChildren() throws {
        guard
            case .caseValue(nil, let branches, .number("0")) = try parse(
                "CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END")
        else { return XCTFail() }
        XCTAssertEqual(branches.count, 1)
        guard case .between(.identifier, .number("1"), .number("10"), false) = branches[0].condition
        else { return XCTFail() }
        guard
            case .caseValue(.identifier, let cases, nil) = try parse(
                "CASE n WHEN 1 THEN 2 WHEN 3 THEN 4 END")
        else { return XCTFail() }
        XCTAssertEqual(cases.count, 2)
        for word in ["NULL", "UNKNOWN", "TRUE", "FALSE"] {
            guard case .isTest(.identifier, let type, true) = try parse("n IS NOT " + word) else {
                return XCTFail(word)
            }
            XCTAssertEqual(type, word.lowercased())
        }
        guard case .inList(.identifier, let items, true) = try parse("n NOT IN (1,2,3)") else {
            return XCTFail()
        }
        XCTAssertEqual(items, [.number("1"), .number("2"), .number("3")])
        guard case .between(_, _, _, true) = try parse("n NOT BETWEEN 1 AND 2") else {
            return XCTFail()
        }
        guard case .pattern("like", _, _, .literal, true) = try parse("n NOT LIKE 'a%' ESCAPE '!' ")
        else { return XCTFail() }
        for op in ["REGEXP", "RLIKE"] {
            guard case .pattern(_, _, _, nil, false) = try parse("v " + op + " 'x'") else {
                return XCTFail(op)
            }
        }
        guard case .tuple(let values) = try parse("(1,2)") else { return XCTFail() }
        XCTAssertEqual(values.count, 2)
    }
    func testNativePrecedenceAndModes() throws {
        guard case .prefix("not", .binary("=", _, _)) = try parse("NOT n=1") else { return XCTFail() }
        guard case .binary("=", .prefix("not", _), _) = try parse("NOT n=1", mode: 1 << 29) else {
            return XCTFail()
        }
        guard case .binary("=", .prefix("!", _), _) = try parse("!n=1") else { return XCTFail() }
        guard case .binary("^", .binary("concat", _, _), _) = try parse("a || b ^ c", mode: 2) else {
            return XCTFail()
        }

    }
    func testAllOperatorsAndSpecialFunctions() throws {
        for sql in [
            "n <=> 1", "n | 1 & 2", "n << 2 >> 1", "n XOR 1", "a && b", "a || b", "-~n",
            "substring(v from 1 for 3)", "substr(v,1)", "mid(v,1,3)", "trim(v)", "trim('x' from v)",
            "trim(both 'x' from v)", "trim(leading from v)", "trim(trailing 'x' from v)", "trim(from v)",
            "extract(YEAR from d)", "timestampdiff(DAY,a,b)", "timestampadd(MONTH,n,d)",
            "position('x' in v)", "convert(v using latin1)", "convert(v,CHAR)",
            "date_add(d,interval 1 day)",
        ] {
            XCTAssertNoThrow(try parse(sql), sql)
        }
        guard case .trim("both", .literal, .identifier) = try parse("trim('x' from v)") else {
            return XCTFail()
        }
        guard case .extract("year", .identifier) = try parse("extract(year from d)") else {
            return XCTFail()
        }
        guard case .convertUsing(.identifier, "latin1") = try parse("convert(v using latin1)") else {
            return XCTFail()
        }
        guard case .interval(.number("1"), "day_second") = try parse("interval 1 day_second") else {
            return XCTFail()
        }
    }
    func testByteAndNumericLiterals() throws {
        for (sql, bytes) in [
            ("X'ABcd'", [UInt8(0xab), 0xcd]), ("b'101'", [5]), ("0b101", [5]), ("0xabc", [10, 188]),
            ("X''", []), ("B''", []),
        ] {
            XCTAssertEqual(try parse(sql), .bytes(Data(bytes)), sql)
        }
        for value in ["0", "001.20", "1.25e-2", "1E+3", ".5", "5.", "1e3", "2.4E+5"] {
            XCTAssertEqual(try parse(value), .number(value), value)
        }
        for sql in ["1 . 2", "X 'AA'", "X'0'", "B'2'", "0xGG", ".x", "2.3e+", "3e-"] {
            XCTAssertThrowsError(try parse(sql), sql)
        }
        XCTAssertEqual(try parse("2x"), .identifier(SQLToken(text: "2x")))
        XCTAssertEqual(try parse("`12`"), .identifier(SQLToken(text: "12", identifier: true)))
        XCTAssertFalse(ExpressionParser.isNumber(""))
        XCTAssertFalse(ExpressionParser.isNumber(".e2"))
    }
    func testMalformedPredicatesAndFunctionsRejectCompleteInput() {
        for sql in [
            "CASE WHEN n THEN END", "CASE END", "CASE n END", "n BETWEEN 1", "n IN ()", "n IS 1",
            "n NOT value", "trim(leading v)", "extract(wrong from d)", "convert(v using)",
            "convert(v using 'latin1')", "abs(n); SELECT 1", "(SELECT n FROM t)", "n LIKE 'x' ESCAPE",
            "position(a)", "timestampadd(DAY,a)",
        ] {
            XCTAssertThrowsError(try parse(sql), sql)
        }
        for sql in [
            "CASE WHEN 1 THEN CASE WHEN 2 THEN 3 END END", "n IN (n IN (1))", "trim(trim(v))",
            "interval interval 1 day day",
        ] {
            XCTAssertThrowsError(try parse(sql, depth: 2), sql)
        }
        XCTAssertThrowsError(
            try parse(Array(repeating: "n IS NULL", count: 140).joined(separator: " OR ")))
    }
}
