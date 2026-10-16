import Foundation

extension ExpressionParser {
  // Scan bytes rather than using a regular expression for numeric grammar.
  static func isNumber(_ text: String) -> Bool {
    let b = Array(text.utf8)
    var n = 0
    var digits = 0
    while n < b.count && (48...57).contains(b[n]) {
      n += 1
      digits += 1
    }
    if n < b.count && b[n] == 46 {
      n += 1
      while n < b.count && (48...57).contains(b[n]) {
        n += 1
        digits += 1
      }
    }
    guard digits > 0 else { return false }
    if n < b.count && (b[n] == 69 || b[n] == 101) {
      n += 1
      if n < b.count && (b[n] == 43 || b[n] == 45) { n += 1 }
      let start = n
      while n < b.count && (48...57).contains(b[n]) { n += 1 }
      guard n > start else { return false }
    }
    return n == b.count
  }
  mutating func numericLiteral(starting token: SQLToken) -> String? {
    guard !token.identifier, let first = token.text.utf8.first,
      (48...57).contains(first) || first == 46
    else { return nil }
    var candidate = token.text
    var best: String?
    var end = i
    var previous = token
    if Self.isNumber(candidate) { best = candidate }
    for next in i..<min(tokens.count, i + 4) {
      let item = tokens[next]
      guard !item.identifier, item.literal == nil, let range = previous.range,
        range.upperBound == item.range?.lowerBound
      else { break }
      candidate += item.text
      previous = item
      if Self.isNumber(candidate) {
        best = candidate
        end = next + 1
      }
    }
    guard let value = best else { return nil }
    i = end
    return value
  }
  func byteConstant(_ digits: String, binary: Bool, allowOdd: Bool = false) throws -> Data {
    if binary {
      try syntaxRequire(digits.utf8.allSatisfy { $0 == 48 || $0 == 49 }, "invalid bit literal")
      let padded = String(repeating: "0", count: (8 - digits.count % 8) % 8) + digits
      let bytes = Array(padded.utf8)
      return Data(
        stride(from: 0, to: bytes.count, by: 8).map { offset in
          bytes[offset..<offset + 8].reduce(UInt8(0)) { ($0 << 1) | ($1 - 48) }
        })
    }
    try syntaxRequire(
      digits.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      } && (allowOdd || digits.count % 2 == 0), "invalid hex literal")
    let padded = (digits.count % 2 == 0 ? "" : "0") + digits
    let bytes = Array(padded.utf8)
    func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 32) - 87 }
    return Data(
      stride(from: 0, to: bytes.count, by: 2).map { nibble(bytes[$0]) * 16 + nibble(bytes[$0 + 1]) }
    )
  }
}
