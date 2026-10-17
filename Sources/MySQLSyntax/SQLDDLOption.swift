/// One bounded DDL option. Statement parsing controls where each option is legal.
/// No server-version or storage-engine rule belongs in this syntax target.
public enum SQLDDLOption: Equatable {
  case indexType(String), keyBlockSize(UInt64), comment(String), parser(String)
  case algorithm(String), lock(String), columnFormat(String), storage(String)

  public static func parseNext(_ tokens:[SQLToken],index:inout Int) throws -> Self? {
    guard index < tokens.count else { return nil }
    let start=index, keyword=tokens[index].keyword
    guard ["USING","TYPE","KEY_BLOCK_SIZE","COMMENT","WITH","ALGORITHM","LOCK","COLUMN_FORMAT","STORAGE"].contains(keyword) else { return nil }
    var cursor=index+1
    func fail() -> SQLSyntaxError { SQLSyntaxError("invalid or incomplete DDL option: "+keyword,range:tokens[start].range) }
    if ["KEY_BLOCK_SIZE","ALGORITHM","LOCK"].contains(keyword),cursor < tokens.count,tokens[cursor].keyword == "=" { cursor += 1 }
    if keyword == "WITH" {
      guard cursor < tokens.count,tokens[cursor].keyword == "PARSER" else { throw fail() }
      cursor += 1
    }
    guard cursor < tokens.count else { throw fail() }
    let value=tokens[cursor],result:Self
    switch keyword {
    case "COMMENT":
      guard let literal=value.literal else { throw fail() }; result = .comment(literal)
    case "KEY_BLOCK_SIZE":
      guard !value.identifier,value.literal == nil,!value.text.isEmpty,
            value.text.utf8.allSatisfy({(48...57).contains($0)}),let number=UInt64(value.text) else { throw fail() }
      result = .keyBlockSize(number)
    case "WITH":
      guard value.literal == nil,(value.identifier || !value.keyword.isEmpty),
            value.text.first.map({$0.isLetter || $0 == "_" || value.identifier}) == true else { throw fail() }
      result = .parser(value.text)
    default:
      let allowed:[String]
      switch keyword {
      case "USING","TYPE": allowed=["BTREE","HASH","RTREE"]
      case "ALGORITHM": allowed=["DEFAULT","COPY","INPLACE","INSTANT"]
      case "LOCK": allowed=["DEFAULT","NONE","SHARED","EXCLUSIVE"]
      case "COLUMN_FORMAT": allowed=["DEFAULT","FIXED","DYNAMIC"]
      default: allowed=["DEFAULT","DISK","MEMORY"]
      }
      guard allowed.contains(value.keyword) else { throw fail() }
      switch keyword {
      case "USING","TYPE": result = .indexType(value.keyword)
      case "ALGORITHM": result = .algorithm(value.keyword)
      case "LOCK": result = .lock(value.keyword)
      case "COLUMN_FORMAT": result = .columnFormat(value.keyword)
      default: result = .storage(value.keyword)
      }
    }
    index=cursor+1
    return result
  }
}
