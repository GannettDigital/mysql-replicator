import Foundation

/// Byte scanner. Token ranges refer to the original input bytes.
public enum SQLLexer {
    public static func lex(
        _ data: Data, sqlMode: UInt64 = 0, characterSet: String = "utf8mb4",
        nativeMetadata: Bool = false,
        decode: ((Data, Bool) throws -> SQLDecodedText)? = nil
    ) throws -> [SQLToken] {
        try syntaxRequire(data.count <= 65536, "DDL statement exceeds 64 KiB")
        if decode == nil {
            try syntaxRequire(String(data: data, encoding: .utf8) != nil, "invalid DDL UTF-8")
        }
        func decoded(_ bytes: [UInt8], identifier: Bool) throws -> SQLDecodedText {
            if let decode { return try decode(Data(bytes), identifier) }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw SQLSyntaxError("invalid DDL literal encoding")
            }
            return SQLDecodedText(text: text, bytes: nil)
        }
        let b = Array(data)
        var i = 0
        var result: [SQLToken] = []
        while i < b.count {
            let c = b[i]
            if [9, 10, 13, 32].contains(c) {
                i += 1
                continue
            }
            if c == 47 && i + 1 < b.count && b[i + 1] == 42 {
                let executable = i + 2 < b.count && b[i + 2] == 33
                try syntaxRequire(!executable || nativeMetadata, "executable DDL comments are unsupported")
                i += 2
                var content = i
                if executable {
                    content += 1
                    while content < b.count && (48...57).contains(b[content]) { content += 1 }
                }
                var quote: UInt8?
                while i + 1 < b.count {
                    if executable, let delimiter = quote {
                        if b[i] == 92 && delimiter != 96 {
                            i += 2
                            continue
                        }
                        if b[i] == delimiter {
                            if b[i + 1] == delimiter {
                                i += 2
                                continue
                            }
                            quote = nil
                        }
                    } else {
                        if b[i] == 42 && b[i + 1] == 47 { break }
                        if executable && [39, 34, 96].contains(b[i]) { quote = b[i] }
                    }
                    i += 1
                }
                try syntaxRequire(i + 1 < b.count, "unterminated DDL comment")
                // Only SHOW CREATE metadata opts in. Source SQL keeps its strict
                // version-comment gate; metadata tokens are never executed.
                if executable {
                    let inner = try lex(
                        Data(b[content..<i]), sqlMode: sqlMode, characterSet: characterSet,
                        nativeMetadata: nativeMetadata, decode: decode)
                    result += inner.map { token in
                        var token = token
                        token.range = token.range.map { ($0.lowerBound + content)..<($0.upperBound + content) }
                        return token
                    }
                }
                try syntaxRequire(result.count <= 16384, "DDL token limit exceeded")
                i += 2
                continue
            }
            if c == 35 || (c == 45 && i + 2 < b.count && b[i + 1] == 45 && b[i + 2] <= 32) {
                while i < b.count && b[i] != 10 { i += 1 }
                continue
            }
            let start = i
            if c == 96 || c == 39 || c == 34 {
                let isIdentifier = c == 96 || (c == 34 && sqlMode & 4 != 0)
                i += 1
                var value: [UInt8] = []
                var closed = false
                while i < b.count {
                    let width = SQLClientEncoding.characterWidth(b, at: i, charset: characterSet)
                    if width > 1 {
                        value.append(contentsOf: b[i..<i + width])
                        i += width
                        continue
                    }
                    if b[i] == c {
                        if i + 1 < b.count && b[i + 1] == c {
                            value.append(c)
                            i += 2
                            continue
                        }
                        i += 1
                        closed = true
                        break
                    }
                    if b[i] == 92 && !isIdentifier && sqlMode & (1 << 20) == 0 {
                        i += 1
                        try syntaxRequire(i < b.count, "truncated DDL escape")
                        if b[i] == 37 || b[i] == 95 { value.append(92) }
                        value.append([UInt8(48): 0, 98: 8, 110: 10, 114: 13, 116: 9, 90: 26][b[i]] ?? b[i])
                        i += 1
                    } else {
                        value.append(b[i])
                        i += 1
                    }
                }
                try syntaxRequire(closed, "unterminated DDL quote")
                let converted = try decoded(value, identifier: isIdentifier)
                if isIdentifier {
                    let name = converted.text
                    result.append(SQLToken(text: name, identifier: true))
                } else {
                    result.append(
                        SQLToken(
                            text: "'" + converted.text.replacingOccurrences(of: "'", with: "''") + "'",
                            literal: converted.text,
                            // An introducer assigns a charset to the input bytes. It bypasses
                            // the ordinary connection-charset conversion.
                            literalBytes: result.last?.keyword.hasPrefix("_") == true ? Data(value) : converted.bytes))
                }
            } else if word(c) {
                let start = i
                repeat {
                    i += SQLClientEncoding.characterWidth(b, at: i, charset: characterSet)
                } while i < b.count && word(b[i])
                let text = try decoded(Array(b[start..<i]), identifier: true).text
                let name = text
                result.append(SQLToken(text: name, identifier: false))
            } else {
                try syntaxRequire(
                    c < 128 && "(),.;=+-*/%@<>!|&^~:?".utf8.contains(c), "unsupported DDL token")
                var text = String(UnicodeScalar(c))
                i += 1
                if i < b.count
                    && ["<=", ">=", "!=", "<>", "<<", ">>", "||", "&&", ":=", "->"].contains(
                        text + String(UnicodeScalar(b[i])))
                {
                    text += String(UnicodeScalar(b[i]))
                    i += 1
                    if (text == "->" || text == "<=") && i < b.count && b[i] == 62 {
                        text += ">"
                        i += 1
                    }
                }
                result.append(SQLToken(text: text))
            }
            result[result.count - 1].range = start..<i
            try syntaxRequire(result.count <= 16384, "DDL token limit exceeded")
        }
        return result
    }
    public static func word(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36
            || c >= 128
    }
}
