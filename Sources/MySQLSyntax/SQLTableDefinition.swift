import Foundation

/// Column slices from a native SHOW CREATE TABLE statement. Ranges refer to
/// the supplied SQL bytes. This helper does not interpret column semantics.
public struct SQLTableColumnSlice: Equatable {
  public let name: String
  public let definition: Range<Int>
}

public enum SQLTableDefinition {
  public static func columns(_ tokens: [SQLToken]) throws -> [SQLTableColumnSlice] {
    try syntaxRequire(tokens.first?.keyword == "CREATE", "expected CREATE TABLE")
    var i = 1
    if i < tokens.count && tokens[i].keyword == "TEMPORARY" { i += 1 }
    try syntaxRequire(i < tokens.count && tokens[i].keyword == "TABLE", "expected CREATE TABLE")
    guard let open = tokens.indices.first(where: { $0 > i && tokens[$0].keyword == "(" }) else {
      throw SQLSyntaxError("missing table definition")
    }
    i = open + 1
    var result: [SQLTableColumnSlice] = []
    while i < tokens.count {
      let start = i
      var depth = 0
      while i < tokens.count {
        let key = tokens[i].keyword
        if depth == 0 && [",", ")"].contains(key) { break }
        if key == "(" { depth += 1 }
        if key == ")" { depth -= 1 }
        try syntaxRequire(key != ";" && depth >= 0, "invalid table definition")
        i += 1
      }
      try syntaxRequire(i > start && i < tokens.count && depth == 0, "incomplete table item")
      let first = tokens[start]
      if !["CONSTRAINT", "PRIMARY", "UNIQUE", "KEY", "INDEX", "FULLTEXT", "SPATIAL", "CHECK", "FOREIGN"].contains(first.keyword) {
        guard i > start + 1, first.literal == nil, let nameRange = first.range,
          let end = tokens[i - 1].range?.upperBound
        else { throw SQLSyntaxError("missing column definition range") }
        result.append(.init(name: first.text, definition: nameRange.upperBound..<end))
      }
      if tokens[i].keyword == ")" {
        try syntaxRequire(!result.isEmpty, "table has no columns")
        return result
      }
      i += 1
    }
    throw SQLSyntaxError("unterminated table definition")
  }
}
