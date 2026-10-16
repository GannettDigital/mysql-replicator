import Foundation

/// Syntax only. Target eligibility and metadata spelling belong to the caller.
public indirect enum SQLExpression: Equatable {
  case literal(SQLToken)
  case identifier(SQLToken)
  case number(String)
  case keyword(String)
  case prefix(String, SQLExpression)
  case binary(String, SQLExpression, SQLExpression)
  case call(String, [SQLExpression])
  case cast(SQLExpression, String)
  case collate(SQLExpression, String)
  case introduced(String, SQLExpression)
  case tuple([SQLExpression])
  case caseValue(SQLExpression?, [SQLWhen], SQLExpression?)
  case between(SQLExpression, SQLExpression, SQLExpression, negated: Bool)
  case inList(SQLExpression, [SQLExpression], negated: Bool)
  case isTest(SQLExpression, String, negated: Bool)
  case pattern(String, SQLExpression, SQLExpression, escape: SQLExpression?, negated: Bool)
  case interval(SQLExpression, String)
  case bytes(Data)
  case trim(String?, SQLExpression?, SQLExpression)
  case extract(String, SQLExpression)
  case convertUsing(SQLExpression, String)

  var treeDepth: Int {
    let children: [SQLExpression]
    switch self {
    case .literal, .identifier, .number, .keyword, .bytes: children = []
    case .prefix(_, let v), .cast(let v, _), .collate(let v, _), .introduced(_, let v),
      .isTest(let v, _, _), .interval(let v, _), .extract(_, let v), .convertUsing(let v, _):
      children = [v]
    case .binary(_, let a, let b): children = [a, b]
    case .call(_, let args), .tuple(let args): children = args
    case .caseValue(let value, let branches, let other):
      children = [value, other].compactMap { $0 } + branches.flatMap { [$0.condition, $0.value] }
    case .between(let a, let b, let c, _): children = [a, b, c]
    case .inList(let value, let items, _): children = [value] + items
    case .pattern(_, let a, let b, let escape, _): children = [a, b] + [escape].compactMap { $0 }
    case .trim(_, let remove, let value): children = [value] + [remove].compactMap { $0 }
    }
    return 1 + (children.map(\.treeDepth).max() ?? 0)
  }

  public static func parse(_ tokens: [SQLToken], sqlMode: UInt64 = 0, maximumDepth: Int = 128)
    throws -> SQLExpression
  {
    var parser = ExpressionParser(tokens: tokens, sqlMode: sqlMode, maximumDepth: maximumDepth)
    do {
      let value = try parser.expression()
      try syntaxRequire(parser.i == tokens.count, "unsupported generated/partition expression")
      return value
    } catch let error as SQLSyntaxError {
      let range = parser.i < tokens.count ? tokens[parser.i].range : tokens.last?.range
      throw SQLSyntaxError(error.message, range: error.range ?? range)
    }
  }
}

public struct SQLWhen: Equatable {
  public let condition: SQLExpression
  public let value: SQLExpression
  public init(condition: SQLExpression, value: SQLExpression) {
    self.condition = condition
    self.value = value
  }
}
