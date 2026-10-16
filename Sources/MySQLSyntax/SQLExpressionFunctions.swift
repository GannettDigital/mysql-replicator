import Foundation

extension ExpressionParser {
  mutating func specialFunction(_ name: String) throws -> SQLExpression? {
    switch name {
    case "position":
      try expect("(")
      let needle = try expression(7)
      try expect("IN")
      let value = try expression()
      try close()
      return .call(name, [needle, value])
    case "substring", "substr", "mid":
      try expect("(")
      let value = try expression()
      if !take(",") { try expect("FROM") }
      let start = try expression()
      var args = [value, start]
      if take(",") || take("FOR") { args.append(try expression()) }
      try close()
      return .call(name, args)
    case "trim":
      try expect("(")
      var direction: String?
      for word in ["BOTH", "LEADING", "TRAILING"] where take(word) {
        direction = word.lowercased()
        break
      }
      if take("FROM") {
        let value = try expression()
        try close()
        return .trim(direction ?? "both", nil, value)
      }
      let first = try expression()
      if take("FROM") {
        let value = try expression()
        try close()
        return .trim(direction ?? "both", first, value)
      }
      try syntaxRequire(direction == nil, "TRIM direction requires FROM")
      try close()
      return .trim(nil, nil, first)
    case "extract":
      try expect("(")
      let unit = try intervalUnit()
      try expect("FROM")
      let value = try expression()
      try close()
      return .extract(unit, value)
    case "timestampadd", "timestampdiff":
      try expect("(")
      let unit = try intervalUnit()
      try expect(",")
      let first = try expression()
      try expect(",")
      let second = try expression()
      try close()
      return .call(name, [.keyword(unit), first, second])
    case "convert":
      let saved = i
      try expect("(")
      let value = try expression()
      guard take("USING") else {
        i = saved
        return nil
      }
      try syntaxRequire(
        i < tokens.count && !tokens[i].text.isEmpty && tokens[i].literal == nil
          && tokens[i].text.utf8.allSatisfy(SQLLexer.word), "missing CONVERT charset")
      let charset = tokens[i].text.lowercased()
      i += 1
      try close()
      return .convertUsing(value, charset)
    default: return nil
    }
  }
  mutating func intervalUnit() throws -> String {
    let units: Set<String> = [
      "MICROSECOND", "SECOND", "MINUTE", "HOUR", "DAY", "WEEK", "MONTH", "QUARTER", "YEAR",
      "SECOND_MICROSECOND", "MINUTE_MICROSECOND", "MINUTE_SECOND", "HOUR_MICROSECOND",
      "HOUR_SECOND", "HOUR_MINUTE", "DAY_MICROSECOND", "DAY_SECOND", "DAY_MINUTE", "DAY_HOUR",
      "YEAR_MONTH",
    ]
    try syntaxRequire(
      i < tokens.count && units.contains(tokens[i].keyword), "invalid interval unit")
    let unit = tokens[i].keyword.lowercased()
    i += 1
    return unit
  }
}
