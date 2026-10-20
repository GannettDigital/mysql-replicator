import Foundation

/// MySQL hexadecimal and bit string literals. These are bytes, not numbers.
enum SQLByteLiteral {
    static func decode(_ digits: String, radix: Int, allowOdd: Bool = true) throws -> Data {
        let width = radix == 16 ? 2 : 8
        try require(radix == 16 || radix == 2, "invalid byte literal radix")
        try require(
            digits.utf8.allSatisfy {
                radix == 2
                    ? (48...49).contains($0)
                    : (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }, "invalid byte literal digits")
        try require(allowOdd || digits.utf8.count % width == 0, "odd hexadecimal string literal")
        let padding = (width - digits.utf8.count % width) % width
        let input = Array((String(repeating: "0", count: padding) + digits).utf8)
        var result = Data()
        for i in stride(from: 0, to: input.count, by: width) {
            guard let value = UInt8(String(decoding: input[i..<i + width], as: UTF8.self), radix: radix) else {
                throw ApplyError("invalid byte literal digits")
            }
            result.append(value)
        }
        return result
    }
    static func sql(_ bytes: Data) -> String { "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" }
    static func parse(_ tokens: [DDLToken]) throws -> Data? {
        if tokens.count == 1 {
            let text = tokens[0].text
            if text.hasPrefix("0x") || text.hasPrefix("0b") {
                try require(text.count > 2, "empty unquoted byte literal")
                return try decode(String(text.dropFirst(2)), radix: text.hasPrefix("0x") ? 16 : 2)
            }
        }
        if tokens.count == 2, let digits = tokens[1].literal, ["X", "B"].contains(tokens[0].keyword) {
            return try decode(digits, radix: tokens[0].keyword == "X" ? 16 : 2, allowOdd: tokens[0].keyword != "X")
        }
        return nil
    }
}
