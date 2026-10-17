import Foundation

/// A bounded CHECK clause. Expression tokens stay opaque because old MySQL
/// sources discard checks without validating constraint expression eligibility.
/// Native version policy and SQL edits do not belong in the syntax target.
public struct SQLCheckClause {
    public let expression: [SQLToken]
    public let consumed: Int
    public let range: Range<Int>?

    public static func parsePrefix(_ tokens: ArraySlice<SQLToken>) throws -> Self {
        let values = Array(tokens)
        guard values.count >= 4, values[0].keyword == "CHECK", values[1].keyword == "(" else {
            throw SQLSyntaxError("expected CHECK (expression)", range: values.first?.range)
        }
        var depth = 1
        for i in 2..<values.count {
            let word = values[i].keyword
            if word == ";" {
                throw SQLSyntaxError("statement separator inside CHECK", range: values[i].range)
            }
            if word == "(" { depth += 1 }
            if word == ")" {
                depth -= 1
                if depth == 0 {
                    guard i > 2 else {
                        throw SQLSyntaxError("empty CHECK expression", range: values[i].range)
                    }
                    let range = values[0].range.flatMap { start in
                        values[i].range.map { start.lowerBound..<$0.upperBound }
                    }
                    return Self(expression: Array(values[2..<i]), consumed: i + 1, range: range)
                }
            }
        }
        throw SQLSyntaxError("unbalanced CHECK parentheses", range: values.first?.range)
    }
}
