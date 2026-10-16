import Foundation

public enum SQLClientEncoding {
  /// Native ismbchar boundaries for encodings whose trailing byte can be
  /// ASCII punctuation. Other supported client encodings cannot hide a quote
  /// or backslash in a multibyte character. Native MySQL converts token values.
  public static func characterWidth(_ b: [UInt8], at i: Int, charset: String) -> Int {
    guard i + 1 < b.count else { return 1 }
    let first = b[i]
    let second = b[i + 1]
    switch charset {
    case "sjis", "cp932":
      return ((0x81...0x9f).contains(first) || (0xe0...0xfc).contains(first))
        && ((0x40...0x7e).contains(second) || (0x80...0xfc).contains(second)) ? 2 : 1
    case "big5":
      return (0xa1...0xf9).contains(first)
        && ((0x40...0x7e).contains(second) || (0xa1...0xfe).contains(second)) ? 2 : 1
    case "gbk", "gb18030":
      guard (0x81...0xfe).contains(first) else { return 1 }
      if (0x40...0xfe).contains(second) && second != 0x7f { return 2 }
      if charset == "gb18030", i + 3 < b.count, (0x30...0x39).contains(second),
        (0x81...0xfe).contains(b[i + 2]), (0x30...0x39).contains(b[i + 3])
      {
        return 4
      }
      return 1
    default: return 1
    }
  }
}
