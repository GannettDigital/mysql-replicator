import Foundation

/// Read the parser for one FULLTEXT index from SHOW CREATE TABLE output.
/// This test oracle is independent of the applier's schema parser. It reads only
/// native metadata, not arbitrary application DDL or executable-comment policy.
enum NativeFulltextParser {
    static func read(_ output: String, index: String) throws -> String {
        guard let tab = output.firstIndex(of: "\t") else { throw LabError("missing SHOW CREATE definition") }
        let tokens = try tokenize(String(output[output.index(after: tab)...]))
        guard tokens.prefix(2) == [.word("CREATE"), .word("TABLE")],
            let start = tokens.firstIndex(of: .symbol("("))
        else { throw LabError("invalid SHOW CREATE TABLE definition") }
        var depth = 1
        var clause: [Token] = []
        var clauses: [[Token]] = []
        var closed = false
        for token in tokens.dropFirst(start + 1) {
            if token == .symbol("(") { depth += 1 }
            if token == .symbol(")") { depth -= 1 }
            if depth == 0 {
                clauses.append(clause)
                closed = true
                break
            }
            if token == .symbol(",") && depth == 1 {
                clauses.append(clause)
                clause = []
            } else {
                clause.append(token)
            }
        }
        try require(closed, "incomplete SHOW CREATE TABLE definition")
        let matches = clauses.filter {
            $0.count >= 4 && $0[0] == .word("FULLTEXT")
                && [.word("KEY"), .word("INDEX")].contains($0[1])
                && $0[2].identifier?.lowercased() == index.lowercased() && $0[3] == .symbol("(")
        }
        try require(matches.count == 1, "missing or duplicate FULLTEXT index " + index)
        let definition = matches[0]
        var parsers: [String] = []
        depth = 0
        for i in 3..<definition.count {
            if definition[i] == .symbol("(") { depth += 1 }
            if definition[i] == .symbol(")") { depth -= 1 }
            if depth == 0 && definition[i] == .word("WITH") {
                try require(
                    i + 2 < definition.count && definition[i + 1] == .word("PARSER"),
                    "invalid FULLTEXT parser clause")
                guard let parser = definition[i + 2].identifier else {
                    throw LabError("missing FULLTEXT parser name")
                }
                parsers.append(parser.lowercased())
            }
        }
        try require(parsers.count == 1, "missing or duplicate parser for FULLTEXT index " + index)
        return parsers[0]
    }

    private enum Token: Equatable {
        case word(String), identifier(String), literal, symbol(Character)
        var identifier: String? {
            switch self {
            case .word(let value), .identifier(let value): return value
            default: return nil
            }
        }
    }

    private static func tokenize(_ sql: String) throws -> [Token] {
        let chars = Array(sql)
        var i = 0
        var tokens: [Token] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                let quote = c
                i += 1
                var value = ""
                var closed = false
                while i < chars.count {
                    let next = chars[i]
                    i += 1
                    if next == quote {
                        if i < chars.count && chars[i] == quote {
                            value.append(quote)
                            i += 1
                        } else {
                            closed = true
                            break
                        }
                    } else if next == "\\" && quote != "`" {
                        try require(i < chars.count, "incomplete SHOW CREATE escape")
                        value.append(chars[i])
                        i += 1
                    } else {
                        value.append(next)
                    }
                }
                try require(closed, "unterminated SHOW CREATE quote")
                tokens.append(quote == "`" ? .identifier(value) : .literal)
            } else if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                let executable = i < chars.count && chars[i] == "!"
                if executable {
                    i += 1
                    while i < chars.count && chars[i].isNumber { i += 1 }
                }
                let start = i
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                try require(i + 1 < chars.count, "unterminated SHOW CREATE comment")
                if executable { tokens += try tokenize(String(chars[start..<i])) }
                i += 2
            } else if c.isLetter || c.isNumber || c == "_" || c == "$" {
                let start = i
                repeat {
                    i += 1
                } while i < chars.count
                    && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$")
                tokens.append(.word(String(chars[start..<i]).uppercased()))
            } else {
                tokens.append(.symbol(c))
                i += 1
            }
        }
        return tokens
    }
}
