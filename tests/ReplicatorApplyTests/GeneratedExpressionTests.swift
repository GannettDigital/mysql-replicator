import Foundation
import XCTest

@testable import ReplicatorApply

final class GeneratedExpressionTests: XCTestCase {
    func testNativePredicateAndCaseMetadata() throws {
        let cases: [(String, String)] = [
            (
                "CASE WHEN n BETWEEN 1 AND 10 THEN n ELSE 0 END",
                "(case when (`n` between 1 and 10) then `n` else 0 end)"
            ),
            ("CASE n WHEN 1 THEN 2 WHEN 3 THEN 4 END", "(case `n` when 1 then 2 when 3 then 4 end)"),
            ("n NOT IN (1,2,3)", "(`n` not in (1,2,3))"),
            ("n IS NOT NULL", "(`n` is not null)"),
            ("(n & 7) << 1", "((`n` & 7) << 1)"),
            ("NOT n=1", "(`n` <> 1)"),
            ("n <=> 1", "(`n` <=> 1)"),
            ("n IN (1)", "(`n` = 1)"),
            ("NOT(n IS NULL)", "(`n` is not null)"),
            ("X'ABCD'", "0xabcd"), ("b'101'", "0x05"),
            ("n IS NULL", "isnull(`n`)"), ("0e3", "0e3"), ("001.20", "1.20"), ("1.25e-2", "1.25e-2"),
        ]
        for (sql, expected) in cases {
            XCTAssertEqual(try DDLExpression.canonical(sql), expected)
            XCTAssertEqual(try DDLExpression.canonical(expected), expected)
        }
        XCTAssertNotEqual(try DDLExpression.canonical("n | 1 & 2"), try DDLExpression.canonical("(n | 1) & 2"))
    }
    func testNativeFunctionSpellings() throws {
        for (left, right) in [
            ("substring(v from 1 for 3)", "substr(`v`,1,3)"),
            ("trim('x' from v)", "trim(both 'x' from `v`)"),
            ("extract(YEAR from d)", "extract(year from `d`)"),
            ("convert(v using latin1)", "convert(`v` using latin1)"),
            ("timestampdiff(DAY,a,b)", "timestampdiff(day,`a`,`b`)"),
            ("greatest(n,10)", "greatest(`n`,10)"),
            ("date_add(d,interval 2 day)", "(`d` + interval 2 day)"),
            ("timestampadd(DAY,n,d)", "(`d` + interval `n` day)"),
            ("position('x' in v)", "locate('x',`v`)"),
            ("convert(v,CHAR)", "cast(`v` as char)"),
            ("mod(n,2)", "(`n` % 2)"),
        ] {
            XCTAssertEqual(try DDLExpression.canonical(left), right)
            XCTAssertEqual(try DDLExpression.canonical(right), right)
        }
    }
    func testModeSpecificOperatorsAndMalformedExpressions() throws {
        XCTAssertEqual(try DDLExpression.canonical(DDLTokens.lex(Data("a || b".utf8)), sqlMode: 2), "concat(`a`,`b`)")
        XCTAssertEqual(try DDLExpression.canonical("a || b"), "(`a` or `b`)")
        XCTAssertEqual(
            try DDLExpression.canonical(DDLTokens.lex(Data("NOT n=1".utf8)), sqlMode: 1 << 29), "((not `n`) = 1)")
        for sql in [
            "CASE WHEN n THEN END", "n BETWEEN 1", "n IN ()", "n IS 1", "n NOT value", "trim(leading v)",
            "abs(n); SELECT 1", "(SELECT n FROM t)",
            String(repeating: "(", count: 150) + "n" + String(repeating: ")", count: 150),
        ] {
            XCTAssertThrowsError(try DDLExpression.canonical(sql), sql)
        }
    }
}
