import Foundation

struct ExpressionParser {
  let tokens: [SQLToken]
  let sqlMode: UInt64
  var i = 0
  var depth = 0
  var resultDepth = 0
  let maximumDepth: Int
  var precedence: [String: Int] {
    [
      "OR": 1, "||": sqlMode & 2 == 0 ? 1 : 14, "XOR": 2, "AND": 3, "&&": 3,
      "BETWEEN": 5, "NOT": 5, "IN": 6, "IS": 6, "LIKE": 6, "REGEXP": 6, "RLIKE": 6,
      "=": 6, "!=": 6, "<>": 6, "<": 6, ">": 6, "<=": 6, ">=": 6, "<=>": 6,
      "|": 7, "&": 8, "<<": 9, ">>": 9, "+": 10, "-": 10, "*": 11, "/": 11, "DIV": 11, "%": 11,
      "MOD": 11,
      "^": 12, "->": 16, "->>": 16, "COLLATE": 15,
    ]
  }
  mutating func expression(_ minimum: Int = 0) throws -> SQLExpression {
    try syntaxRequire(depth < maximumDepth, "SQL expression nesting limit exceeded")
    depth += 1
    defer { depth -= 1 }
    try syntaxRequire(i < tokens.count, "missing generated/partition expression")
    let token = tokens[i]
    i += 1
    var lhs: SQLExpression
    var lhsDepth = 1
    if token.keyword == "(" {
      var values = [try expression()]
      while take(",") { values.append(try expression()) }
      try close()
      lhs = values.count == 1 ? values[0] : .tuple(values)
      lhsDepth = lhs.treeDepth
    } else if token.keyword == "CASE" {
      lhs = try caseExpression()
      lhsDepth = lhs.treeDepth
    } else if ["+", "-", "NOT", "!", "~"].contains(token.keyword) {
      let level = token.keyword == "NOT" && sqlMode & (1 << 29) == 0 ? 4 : 13
      lhs = .prefix(token.keyword.lowercased(), try expression(level))
      lhsDepth = resultDepth + 1
    } else if token.keyword == "INTERVAL" {
      let value = try expression(10)
      lhs = .interval(value, try intervalUnit())
      lhsDepth = value.treeDepth + 1
    } else if ["X", "B"].contains(token.keyword), i < tokens.count, let digits = tokens[i].literal {
      try syntaxRequire(
        token.range?.upperBound == tokens[i].range?.lowerBound, "separated byte literal")
      i += 1
      lhs = .bytes(try byteConstant(digits, binary: token.keyword == "B"))
    } else if token.keyword.hasPrefix("0X") {
      lhs = .bytes(try byteConstant(String(token.text.dropFirst(2)), binary: false, allowOdd: true))
    } else if token.text.hasPrefix("0b") {
      lhs = .bytes(try byteConstant(String(token.text.dropFirst(2)), binary: true))
    } else if token.keyword.hasPrefix("_"), i < tokens.count,
      tokens[i].literal != nil || tokens[i].keyword.hasPrefix("0X")
        || ["X", "B"].contains(tokens[i].keyword) || tokens[i].text.hasPrefix("0b") {
      let literal = try expression(16)
      lhs = .introduced(token.keyword.lowercased(), literal)
      lhsDepth = resultDepth + 1
    } else if ["DATE", "TIME", "TIMESTAMP"].contains(token.keyword),
      i < tokens.count, tokens[i].literal != nil
    {
      lhs = .cast(.literal(tokens[i]), token.keyword == "TIMESTAMP" ? "datetime" : token.keyword.lowercased())
      i += 1
      lhsDepth = 2
    } else if token.literal != nil {
      lhs = .literal(token)
    } else if let number = numericLiteral(starting: token) {
      lhs = .number(number)
    } else if i < tokens.count && tokens[i].keyword == "(" {
      let function = token.keyword.lowercased()
      if let special = try specialFunction(function) {
        lhs = special
        lhsDepth = special.treeDepth
      } else if function == "cast" || function == "convert" {
        i += 1
        let value = try expression()
        let valueDepth = resultDepth
        try syntaxRequire(
          i < tokens.count && tokens[i].keyword == (function == "cast" ? "AS" : ","),
          "missing CAST type")
        i += 1
        try syntaxRequire(i < tokens.count, "missing CAST type")
        var type = tokens[i].keyword.lowercased()
        i += 1
        try syntaxRequire(
          [
            "char", "binary", "signed", "unsigned", "decimal", "date", "datetime", "time", "json",
            "float", "double", "real",
          ].contains(type), "unsupported CAST type")
        if ["signed", "unsigned"].contains(type), i < tokens.count, tokens[i].keyword == "INTEGER" {
          i += 1
        }
        if i < tokens.count && tokens[i].keyword == "(" {
          i += 1
          var sizes: [String] = []
          repeat {
            try syntaxRequire(
              i < tokens.count && !tokens[i].text.isEmpty
                && tokens[i].text.utf8.allSatisfy { (48...57).contains($0) }, "invalid CAST width")
            sizes.append(tokens[i].text)
            i += 1
            if i < tokens.count && tokens[i].keyword == "," { i += 1 } else { break }
          } while true
          try close()
          type += "(" + sizes.joined(separator: ",") + ")"
        }
        if i < tokens.count && ["CHARSET", "CHARACTER"].contains(tokens[i].keyword) {
          let long = tokens[i].keyword == "CHARACTER"
          i += 1
          if long {
            try syntaxRequire(
              i < tokens.count && tokens[i].keyword == "SET", "missing CAST CHARACTER SET")
            i += 1
          }
          try syntaxRequire(
            i < tokens.count && tokens[i].text.utf8.allSatisfy(SQLLexer.word),
            "missing CAST charset")
          let charset = tokens[i].text.lowercased()
          i += 1
          type += " charset " + charset
        }
        try close()
        lhs = .cast(value, type)
        lhsDepth = valueDepth + 1
      } else {
        try syntaxRequire(
          !function.isEmpty && function.utf8.allSatisfy(SQLLexer.word),
          "invalid expression function")
        i += 1
        var arguments: [SQLExpression] = []
        while i < tokens.count && tokens[i].keyword != ")" {
          arguments.append(try expression())
          lhsDepth = max(lhsDepth, resultDepth + 1)
          if i < tokens.count && tokens[i].keyword == "," {
            i += 1
            try syntaxRequire(
              i < tokens.count && tokens[i].keyword != ")", "missing function argument")
          } else {
            break
          }
        }
        try close()
        lhs = .call(function, arguments)
      }
    } else if ["NULL", "TRUE", "FALSE"].contains(token.keyword) {
      lhs = .keyword(token.keyword.lowercased())
    } else {
      try syntaxRequire(
        token.identifier || token.text.utf8.allSatisfy(SQLLexer.word),
        "unsupported expression operand")
      lhs = .identifier(token)
    }
    try syntaxRequire(lhsDepth <= maximumDepth, "SQL expression tree depth limit exceeded")
    while i < tokens.count, let level = precedence[tokens[i].keyword], level >= minimum {
      let op = tokens[i].keyword.lowercased()
      i += 1
      if ["not", "between", "in", "is", "like", "regexp", "rlike"].contains(op) {
        lhs = try predicate(lhs, op: op, level: level)
        lhsDepth = lhs.treeDepth
        try syntaxRequire(lhsDepth <= maximumDepth, "SQL expression tree depth limit exceeded")
        continue
      }
      if op == "collate" {
        try syntaxRequire(
          i < tokens.count && tokens[i].literal == nil
            && tokens[i].text.utf8.allSatisfy(SQLLexer.word), "missing expression collation")
        lhs = .collate(lhs, tokens[i].text.lowercased())
        lhsDepth += 1
        try syntaxRequire(lhsDepth <= maximumDepth, "SQL expression tree depth limit exceeded")
        i += 1
        continue
      }
      let rhs = try expression(level + 1)
      lhsDepth = max(lhsDepth, resultDepth) + 1
      try syntaxRequire(lhsDepth <= maximumDepth, "SQL expression tree depth limit exceeded")
      lhs = .binary(op == "||" && sqlMode & 2 != 0 ? "concat" : op, lhs, rhs)
    }
    resultDepth = lhsDepth
    return lhs
  }
  mutating func close() throws {
    try syntaxRequire(i < tokens.count && tokens[i].keyword == ")", "unbalanced expression")
    i += 1
  }
}
