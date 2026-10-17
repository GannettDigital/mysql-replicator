import Foundation

/// A token keeps its source range even when its decoded value has another encoding.
public struct SQLToken: Equatable {
  public var text: String
  public var identifier: Bool
  public var literal: String?
  public var literalBytes: Data?
  public var range: Range<Int>?

  public init(
    text: String, identifier: Bool = false, literal: String? = nil,
    literalBytes: Data? = nil, range: Range<Int>? = nil
  ) {
    self.text = text
    self.identifier = identifier
    self.literal = literal
    self.literalBytes = literalBytes
    self.range = range
  }

  public var keyword: String {
    guard !identifier, literal == nil, text.utf8.allSatisfy({ $0 < 128 }) else { return "" }
    return text.uppercased()
  }

  // Swift's canonical Unicode equality does not match MySQL identifier bytes.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.identifier == rhs.identifier
      && lhs.literal.map { Array($0.utf8) } == rhs.literal.map { Array($0.utf8) }
      && lhs.literalBytes == rhs.literalBytes
  }
}

public struct SQLDecodedText {
  public let text: String
  public let bytes: Data?
  public init(text: String, bytes: Data?) {
    self.text = text
    self.bytes = bytes
  }
}

public struct SQLSyntaxError: Error, CustomStringConvertible {
  public let message: String
  public let range: Range<Int>?
  public var description: String { message }
  public init(_ message: String, range: Range<Int>? = nil) {
    self.message = message
    self.range = range
  }
}

func syntaxRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw SQLSyntaxError(message) }
}
