/// Parsed partition grammar. Engine and version policy belong to the caller.
public struct SQLPartitionMethod: Equatable {
  public let name: String
  public let expression: [SQLToken]
  public let algorithm: Int?
}

public struct SQLPartitionItem: Equatable {
  public let name: String
  public let range: Bool?
  public let values: [SQLToken]?
  public let engine: String?
  public let children: [SQLPartitionItem]
  public static func generated(name: String) -> Self {
    Self(name: name, range: nil, values: nil, engine: nil, children: [])
  }
}

public struct SQLPartitionClause: Equatable {
  public let method: SQLPartitionMethod
  public let count: Int?
  public let subpartition: SQLPartitionMethod?
  public let subpartitionCount: Int?
  public let items: [SQLPartitionItem]
  public let consumed: Int

  /// Input starts at BY, after the caller consumes PARTITION.
  public static func parsePrefix(_ tokens: ArraySlice<SQLToken>) throws -> Self {
    var parser = PartitionParser(tokens: Array(tokens))
    try parser.expect("BY")
    let method = try parser.method()
    let count = try parser.count("PARTITIONS")
    var subpartition: SQLPartitionMethod?
    var subpartitionCount: Int?
    if parser.take("SUBPARTITION") {
      try parser.expect("BY")
      subpartition = try parser.method()
      try syntaxRequire(
        method.name.hasPrefix("RANGE") || method.name.hasPrefix("LIST"),
        "subpartitions require RANGE or LIST partitions")
      try syntaxRequire(
        subpartition!.name.contains("HASH") || subpartition!.name.contains("KEY"),
        "subpartition method must be HASH or KEY")
      try syntaxRequire(!subpartition!.expression.isEmpty, "empty subpartition expression")
      subpartitionCount = try parser.count("SUBPARTITIONS")
    }
    let items = parser.peek("(") ? try parser.items(subpartitions: false) : []
    try syntaxRequire(
      !items.isEmpty || method.name.contains("HASH") || method.name.contains("KEY"),
      "RANGE/LIST partitions require definitions")
    if let count, !items.isEmpty {
      try syntaxRequire(count == items.count, "partition count differs from definitions")
    }
    if subpartition == nil {
      try syntaxRequire(
        items.allSatisfy { $0.children.isEmpty }, "subpartition definitions require a method")
    }
    return Self(
      method: method, count: count, subpartition: subpartition,
      subpartitionCount: subpartitionCount, items: items, consumed: parser.index)
  }

  /// ADD and REORGANIZE inherit their method from the existing table.
  public static func parseItemsPrefix(_ tokens: ArraySlice<SQLToken>) throws -> (
    items: [SQLPartitionItem], consumed: Int
  ) {
    var parser = PartitionParser(tokens: Array(tokens))
    let items = try parser.items(subpartitions: false)
    return (items, parser.index)
  }
}

private struct PartitionParser {
  let tokens: [SQLToken]
  var index = 0
  func peek(_ word: String) -> Bool { index < tokens.count && tokens[index].keyword == word }
  mutating func take(_ word: String) -> Bool {
    guard peek(word) else { return false }
    index += 1
    return true
  }
  mutating func expect(_ word: String) throws {
    guard take(word) else {
      throw SQLSyntaxError(
        "expected \(word) in partition definition",
        range: tokens.indices.contains(index) ? tokens[index].range : nil)
    }
  }
  mutating func identifier() throws -> String {
    guard index < tokens.count else { throw SQLSyntaxError("missing partition identifier") }
    let token = tokens[index]
    try syntaxRequire(
      token.identifier
        || (token.literal == nil && !token.text.isEmpty
          && token.text.unicodeScalars.allSatisfy {
            $0.value >= 128 || $0 == "_" || $0 == "$" || (65...90).contains($0.value)
              || (97...122).contains($0.value) || (48...57).contains($0.value)
          }),
      "invalid partition identifier")
    index += 1
    return token.text
  }
  mutating func identifierOrText() throws -> String {
    if index < tokens.count, let text = tokens[index].literal {
      index += 1
      return text
    }
    return try identifier()
  }
  mutating func number() throws -> Int {
    guard index < tokens.count, tokens[index].literal == nil, !tokens[index].identifier,
      let value = Int(tokens[index].text), value > 0, value <= 8192
    else { throw SQLSyntaxError("partition count must be between 1 and 8192") }
    index += 1
    return value
  }
  mutating func count(_ word: String) throws -> Int? { try take(word) ? number() : nil }
  mutating func parentheses() throws -> [SQLToken] {
    try expect("(")
    let start = index
    var depth = 1
    while index < tokens.count {
      let token = tokens[index]
      try syntaxRequire(token.keyword != ";", "statement separator in partition expression")
      if token.keyword == "(" { depth += 1 }
      if token.keyword == ")" { depth -= 1 }
      index += 1
      if depth == 0 { return Array(tokens[start..<(index - 1)]) }
    }
    throw SQLSyntaxError("unbalanced partition parentheses")
  }
  mutating func method() throws -> SQLPartitionMethod {
    let linear = take("LINEAR")
    var name = try identifier().uppercased()
    try syntaxRequire(["RANGE", "LIST", "HASH", "KEY"].contains(name), "invalid partition method")
    if linear {
      try syntaxRequire(name == "HASH" || name == "KEY", "LINEAR requires HASH or KEY")
      name = "LINEAR " + name
    }
    if take("COLUMNS") {
      try syntaxRequire(name == "RANGE" || name == "LIST", "COLUMNS requires RANGE or LIST")
      name += " COLUMNS"
    }
    var algorithm: Int?
    if take("ALGORITHM") {
      try syntaxRequire(name.contains("KEY"), "ALGORITHM requires KEY")
      try expect("=")
      algorithm = try number()
      try syntaxRequire(algorithm == 1 || algorithm == 2, "KEY algorithm must be 1 or 2")
    }
    let expression = try parentheses()
    try syntaxRequire(!expression.isEmpty || name.contains("KEY"), "empty partition expression")
    return .init(name: name, expression: expression, algorithm: algorithm)
  }
  mutating func items(subpartitions: Bool) throws -> [SQLPartitionItem] {
    try expect("(")
    var result: [SQLPartitionItem] = []
    repeat {
      try expect(subpartitions ? "SUBPARTITION" : "PARTITION")
      let name = try subpartitions ? identifierOrText() : identifier()
      var range: Bool?
      var values: [SQLToken]?
      if !subpartitions && take("VALUES") {
        range = take("LESS")
        try expect(range! ? "THAN" : "IN")
        if take("MAXVALUE") {
          values = [tokens[index - 1]]
        } else {
          values = try parentheses()
          try syntaxRequire(!values!.isEmpty, "empty partition values")
        }
      }
      let engine = try options()
      let children = !subpartitions && peek("(") ? try items(subpartitions: true) : []
      result.append(
        .init(name: name, range: range, values: values, engine: engine, children: children))
      try syntaxRequire(result.count <= 8192, "too many partition definitions")
    } while take(",")
    try expect(")")
    return result
  }
  mutating func options() throws -> String? {
    var engine: String?
    while index < tokens.count {
      var option = tokens[index].keyword
      guard
        [
          "ENGINE", "STORAGE", "COMMENT", "DATA", "INDEX", "MAX_ROWS", "MIN_ROWS", "TABLESPACE",
          "NODEGROUP",
        ].contains(option)
      else { break }
      index += 1
      if option == "STORAGE" {
        try expect("ENGINE")
        option = "ENGINE"
      }
      if option == "DATA" || option == "INDEX" { try expect("DIRECTORY") }
      _ = take("=")
      if ["COMMENT", "DATA", "INDEX"].contains(option) {
        try syntaxRequire(
          index < tokens.count && tokens[index].literal != nil, "partition option requires a string"
        )
        index += 1
      } else if ["MAX_ROWS", "MIN_ROWS", "NODEGROUP"].contains(option) {
        try syntaxRequire(
          index < tokens.count && tokens[index].literal == nil && !tokens[index].identifier
            && UInt64(tokens[index].text) != nil, "partition option requires an unsigned integer")
        index += 1
      } else {
        let value = try option == "ENGINE" ? identifierOrText() : identifier()
        if option == "ENGINE" { engine = value }
      }
    }
    return engine
  }
}

extension SQLPartitionClause {
  /// SHOW CREATE tokens have already expanded version comments in metadata mode.
  /// Ignore keyword-like text inside the column list, quoted names and literals.
  public static func fromCreateTable(_ tokens: [SQLToken]) throws -> Self? {
    var depth = 0
    for i in tokens.indices {
      if tokens[i].keyword == "(" { depth += 1 }
      if tokens[i].keyword == ")" { depth -= 1 }
      try syntaxRequire(depth >= 0, "invalid native CREATE parentheses")
      if depth == 0 && tokens[i].keyword == "PARTITION" && i + 1 < tokens.count
        && tokens[i + 1].keyword == "BY"
      {
        let clause = try parsePrefix(tokens[(i + 1)...])
        try syntaxRequire(
          i + 1 + clause.consumed == tokens.count, "unexpected native partition suffix")
        return clause
      }
    }
    try syntaxRequire(depth == 0, "unbalanced native CREATE parentheses")
    return nil
  }
}
