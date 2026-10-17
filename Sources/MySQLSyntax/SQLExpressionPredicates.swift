import Foundation

extension ExpressionParser {
  mutating func take(_ word: String) -> Bool {
    if i < tokens.count, tokens[i].keyword == word {
      i += 1
      return true
    }
    return false
  }
  mutating func expect(_ word: String) throws {
    try syntaxRequire(take(word), "expression requires " + word)
  }
  mutating func caseExpression() throws -> SQLExpression {
    let value = i < tokens.count && tokens[i].keyword != "WHEN" ? try expression() : nil
    var branches: [SQLWhen] = []
    while take("WHEN") {
      let condition = try expression()
      try expect("THEN")
      branches.append(.init(condition: condition, value: try expression()))
    }
    try syntaxRequire(!branches.isEmpty, "CASE requires WHEN")
    let other = take("ELSE") ? try expression() : nil
    try expect("END")
    return .caseValue(value, branches, other)
  }
  mutating func predicate(_ lhs: SQLExpression, op: String, level: Int) throws -> SQLExpression {
    var op = op
    var negative = false
    if op == "not" {
      try syntaxRequire(
        i < tokens.count
          && ["BETWEEN", "IN", "LIKE", "REGEXP", "RLIKE"].contains(tokens[i].keyword),
        "invalid infix NOT")
      negative = true
      op = tokens[i].keyword.lowercased()
      i += 1
    }
    if op == "between" {
      let lower = try expression(6)
      try expect("AND")
      return .between(lhs, lower, try expression(6), negated: negative)
    }
    if op == "in" {
      try expect("(")
      var values: [SQLExpression] = []
      repeat { values.append(try expression()) } while take(",")
      try close()
      return .inList(lhs, values, negated: negative)
    }
    if op == "is" {
      let negative = take("NOT")
      try syntaxRequire(
        i < tokens.count && ["NULL", "UNKNOWN", "TRUE", "FALSE"].contains(tokens[i].keyword),
        "invalid IS predicate")
      let value = tokens[i].keyword.lowercased()
      i += 1
      return .isTest(lhs, value, negated: negative)
    }
    let rhs = try expression(level + 1)
    let escape = op == "like" && take("ESCAPE") ? try expression(level + 1) : nil
    return .pattern(op, lhs, rhs, escape: escape, negated: negative)
  }
}
