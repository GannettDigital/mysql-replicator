/// ALTER operations that keep the column and constraint definitions unchanged.
/// The target engine decides how to rebuild the table and maintain its indexes.
public enum SQLAlterMaintenance: Equatable {
  case force
  case enableKeys
  case disableKeys

  public static func parse(_ tokens: [SQLToken]) throws -> Self {
    let words = tokens.map(\.keyword)
    switch words {
    case ["FORCE"]: return .force
    case ["ENABLE", "KEYS"]: return .enableKeys
    case ["DISABLE", "KEYS"]: return .disableKeys
    default:
      throw SQLSyntaxError(
        "expected FORCE, ENABLE KEYS or DISABLE KEYS", range: tokens.first?.range)
    }
  }
}
