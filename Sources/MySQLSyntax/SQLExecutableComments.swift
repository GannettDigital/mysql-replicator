import Foundation

/// Builds a parsing view using the target server version. Never execute this
/// view: send the original version comments to MySQL.
public enum SQLExecutableComments {
  private static func space(_ c: UInt8) -> Bool { [9, 10, 11, 12, 13, 32].contains(c) }
  private static func body(_ b: [UInt8], at start: Int, sixDigitVersions: Bool) -> Int {
    let digits = start + 3
    guard digits + 5 <= b.count, b[digits..<digits + 5].allSatisfy({ (48...57).contains($0) }) else { return digits }
    if sixDigitVersions, digits + 6 < b.count, (48...57).contains(b[digits + 5]), space(b[digits + 6]) { return digits + 6 }
    return digits + 5
  }

  /// Replace wrapper bytes with spaces. All other bytes and offsets stay intact.
  public static func parsingView(_ data: Data, serverVersion: Int, sqlMode: UInt64 = 0, characterSet: String = "utf8mb4") throws -> Data {
    try syntaxRequire(data.count <= 65536, "DDL statement exceeds 64 KiB")
    guard data.range(of: Data("/*!".utf8)) != nil else { return data }
    let b = Array(data)
    var output = b, i = 0, depth = 0
    while i < b.count {
      let c = b[i]
      if [39, 34, 96].contains(c) {
        let identifier = c == 96 || (c == 34 && sqlMode & 4 != 0)
        i += 1
        var closed = false
        while i < b.count {
          let width = SQLClientEncoding.characterWidth(b, at: i, charset: characterSet)
          if width > 1 { i += width; continue }
          if b[i] == c {
            if i + 1 < b.count && b[i + 1] == c { i += 2; continue }
            i += 1; closed = true; break
          }
          if b[i] == 92 && !identifier && sqlMode & (1 << 20) == 0 { i += 1 }
          i += 1
        }
        try syntaxRequire(closed, "unterminated DDL quote")
      } else if c == 35 || (c == 45 && i + 2 < b.count && b[i + 1] == 45 && b[i + 2] <= 32) {
        while i < b.count && b[i] != 10 { i += 1 }
      } else if c == 47 && i + 1 < b.count && b[i + 1] == 42 {
        if i + 2 < b.count && b[i + 2] == 33 {
          let end = body(b, at: i, sixDigitVersions: serverVersion >= 80400)
          let version = Int(String(decoding: b[(i + 3)..<end], as: UTF8.self)) ?? 0
          let start = i
          if version > serverVersion {
            // Native inactive comments do not parse quotes. They permit one
            // nested block comment, then resume at the outer closing marker.
            i = end
            var nested = false, closed = false
            while i + 1 < b.count {
              if !nested && b[i] == 47 && b[i + 1] == 42 { nested = true; i += 2; continue }
              if b[i] == 42 && b[i + 1] == 47 {
                i += 2
                if nested { nested = false; continue }
                closed = true; break
              }
              i += 1
            }
            try syntaxRequire(closed, "unterminated inactive DDL comment")
            for index in start..<i { output[index] = 32 }
          } else {
            for index in i..<end { output[index] = 32 }
            i = end; depth += 1
          }
          try syntaxRequire(depth <= 64, "executable comment nesting limit exceeded")
        } else {
          i += 2
          while i + 1 < b.count && !(b[i] == 42 && b[i + 1] == 47) { i += 1 }
          try syntaxRequire(i + 1 < b.count, "unterminated DDL comment")
          i += 2
        }
      } else if depth > 0 && c == 42 && i + 1 < b.count && b[i + 1] == 47 {
        output[i] = 32; output[i + 1] = 32
        i += 2; depth -= 1
      } else {
        i += SQLClientEncoding.characterWidth(b, at: i, charset: characterSet)
      }
    }
    try syntaxRequire(depth == 0, "unterminated executable DDL comment")
    return Data(output)
  }

  /// Capture only needs the first keyword. Do not parse literals or statement
  /// bodies here: Query-event SQL mode and charset belong to the apply stage.
  public static func leadingKeyword(_ data: Data) -> String? {
    let b = Array(data.prefix(65536))
    var i = 0, depth = 0
    while i < b.count {
      if space(b[i]) { i += 1; continue }
      if b[i] == 35 || (b[i] == 45 && i + 2 < b.count && b[i + 1] == 45 && b[i + 2] <= 32) {
        while i < b.count && b[i] != 10 { i += 1 }
        continue
      }
      if b[i] == 47 && i + 1 < b.count && b[i + 1] == 42 {
        if i + 2 < b.count && b[i + 2] == 33 {
          i = body(b, at: i, sixDigitVersions: true); depth += 1
        } else {
          i += 2
          while i + 1 < b.count && !(b[i] == 42 && b[i + 1] == 47) { i += 1 }
          guard i + 1 < b.count else { return nil }
          i += 2
        }
        continue
      }
      if depth > 0 && b[i] == 42 && i + 1 < b.count && b[i + 1] == 47 {
        i += 2; depth -= 1; continue
      }
      let start = i
      while i < b.count && ((65...90).contains(b[i]) || (97...122).contains(b[i]) || b[i] == 95) { i += 1 }
      return i > start ? String(decoding: b[start..<i], as: UTF8.self).uppercased() : nil
    }
    return nil
  }
}
