import Foundation
import MySQLSyntax

typealias DDLToken = SQLToken

enum DDLTokens {
    static func requiresConnectionCollation(_ tokens: [DDLToken]) -> Bool {
        for (i, token) in tokens.enumerated() {
            if ["AS", "PROCEDURE", "FUNCTION", "VIEW"].contains(token.keyword) { return true }
            if let literal = token.literal {
                let engineOption =
                    i > 0
                    && (tokens[i - 1].keyword == "ENGINE"
                        || (i > 1 && tokens[i - 1].keyword == "=" && tokens[i - 2].keyword == "ENGINE"))
                if !engineOption || !["MYISAM", "DEFAULT"].contains(literal.uppercased()) { return true }
            }
        }
        return false
    }
    static func lex(
        _ data: Data, sqlMode: UInt64 = 0, characterSet: String = "utf8mb4", nativeMetadata: Bool = false,
        decode: ((Data, Bool) throws -> DDLDecodedText)? = nil
    ) throws -> [DDLToken] {
        do {
            return try SQLLexer.lex(
                data, sqlMode: sqlMode, characterSet: characterSet,
                nativeMetadata: nativeMetadata, decode: decode
            ).map { token in
                var token = token
                if token.identifier || (token.literal == nil && token.text.utf8.allSatisfy(SQLLexer.word)) {
                    let name = SQLIdentifier.storedName(token.text)
                    if token.identifier {
                        _ = try quoted(name)
                    } else if !SQLTextBytes.equal(token.text, name) {
                        token.identifier = true
                    }
                    token.text = name
                }
                return token
            }
        } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
    }
    static func word(_ byte: UInt8) -> Bool { SQLLexer.word(byte) }
}

/// Canonical expressions for schema comparison; SQL still runs on the target. Canonical AST
/// spelling equates MySQL's added parentheses/backticks without losing grouping.
enum DDLExpression {
    static func references(_ name: String, in expression: String) throws -> Bool {
        try DDLTokens.lex(Data(expression.utf8), sqlMode: 1 << 20).contains {
            $0.identifier && SQLIdentifier.equal($0.text, name)
        }
    }
    static func canonical(_ sql: String) throws -> String {
        try canonical(DDLTokens.lex(Data(sql.utf8), sqlMode: 1 << 20))
    }
    static func canonical(_ tokens: [DDLToken], sqlMode: UInt64 = 0) throws -> String {
        do { return try render(SQLExpression.parse(tokens, sqlMode: sqlMode)) } catch let error as SQLSyntaxError {
            throw ApplyError(error.message)
        }
    }

    static func render(_ expression: SQLExpression) throws -> String {
        switch expression {
        case .literal(let token):
            return "'" + (token.literal ?? "").replacingOccurrences(of: "'", with: "''") + "'"
        case .identifier(let token): return try quoted(token.text)
        case .number(let value):
            var value = value.lowercased()
            if value.contains("e") { return value }
            while value.count > 1, value.first == "0", value.dropFirst().first != "." { value.removeFirst() }
            return value.first == "." ? "0" + value : value
        case .keyword(let value): return value == "true" ? "1" : value == "false" ? "0" : value
        case .prefix(let op, let value):
            if op == "not" || op == "!" { return try negating(value) }
            if op == "+" { return try render(value) }
            return "(" + op + " " + (try render(value)) + ")"
        case .introduced(let name, let value): return (name == "_utf8mb4" ? "" : name) + (try render(value))
        case .cast(let value, let type):
            let metadataType = type.replacingOccurrences(of: " charset utf8mb4", with: "")
            return "cast(" + (try render(value)) + " as " + metadataType + ")"
        case .collate(let value, let name): return "(" + (try render(value)) + " collate " + name + ")"
        case .call(let name, let args): return try renderCall(name, args)
        case .binary(let op, let left, let right):
            let lhs = try render(left)
            let rhs = try render(right)
            if op == "->" || op == "->>" {
                let extracted = "json_extract(" + lhs + "," + rhs + ")"
                return op == "->>" ? "json_unquote(" + extracted + ")" : extracted
            }
            if op == "concat" { return "concat(" + lhs + "," + rhs + ")" }
            let op = ["&&": "and", "||": "or", "!=": "<>", "mod": "%"][op] ?? op
            return "(" + lhs + " " + op + " " + rhs + ")"
        case .tuple(let values): return "(" + (try values.map(render)).joined(separator: ",") + ")"
        case .caseValue(let value, let branches, let other):
            var result = "(case "
            if let value { result += try render(value) + " " }
            for branch in branches {
                result += try "when " + render(branch.condition) + " then " + render(branch.value) + " "
            }
            if let other { result += try "else " + render(other) + " " }
            return result + "end)"
        case .between(let value, let lower, let upper, let negative):
            return try "(" + render(value) + (negative ? " not" : "") + " between " + render(lower) + " and "
                + render(upper) + ")"
        case .inList(let value, let items, let negative):
            if items.count == 1 { return try render(.binary(negative ? "<>" : "=", value, items[0])) }
            return try "(" + render(value) + (negative ? " not" : "") + " in ("
                + items.map(render).joined(separator: ",") + "))"
        case .isTest(let value, let type, let negative):
            let type = type == "unknown" ? "null" : type
            if type == "null", !negative { return try "isnull(" + render(value) + ")" }
            return try "(" + render(value) + (negative ? " is not " : " is ") + type + ")"
        case .pattern(let op, let value, let pattern, let escape, let negative):
            var result =
                try "(" + render(value) + (negative ? " not " : " ") + (op == "rlike" ? "regexp" : op) + " "
                + render(pattern)
            if let escape { result += try " escape " + render(escape) }
            return result + ")"
        case .interval(let value, let unit): return try "interval " + render(value) + " " + unit
        case .bytes(let bytes): return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        case .trim(let direction, let remove, let value):
            if let direction {
                return try "trim(" + direction + " " + (remove.map(render) ?? "' '") + " from " + render(value) + ")"
            }
            return try "trim(" + render(value) + ")"
        case .extract(let unit, let value): return try "extract(" + unit + " from " + render(value) + ")"
        case .convertUsing(let value, let charset): return try "convert(" + render(value) + " using " + charset + ")"
        }
    }

    private static func renderCall(_ name: String, _ args: [SQLExpression]) throws -> String {
        if name == "mod", args.count == 2 { return try render(.binary("%", args[0], args[1])) }
        if ["date_add", "date_sub", "adddate", "subdate"].contains(name), args.count == 2 {
            let amount: SQLExpression
            if case .interval = args[1] { amount = args[1] } else { amount = .interval(args[1], "day") }
            return try render(.binary(["date_sub", "subdate"].contains(name) ? "-" : "+", args[0], amount))
        }
        if name == "timestampadd", args.count == 3, case .keyword(let unit) = args[0] {
            return try render(.binary("+", args[2], .interval(args[1], unit)))
        }
        let name =
            [
                "power": "pow", "lcase": "lower", "ucase": "upper", "character_length": "char_length",
                "ceil": "ceiling", "substring": "substr", "mid": "substr", "position": "locate",
            ][name] ?? name
        return name + "(" + (try args.map(render)).joined(separator: ",") + ")"
    }
    private static func negating(_ value: SQLExpression) throws -> String {
        switch value {
        case .binary(let op, let left, let right):
            if let inverse = ["=": "<>", "<>": "=", "!=": "=", "<": ">=", ">": "<=", "<=": ">", ">=": "<"][op] {
                return try render(.binary(inverse, left, right))
            }
        case .isTest(let operand, let type, let negative): return try render(.isTest(operand, type, negated: !negative))
        case .call("isnull", let args) where args.count == 1: return try render(.isTest(args[0], "null", negated: true))
        case .between(let operand, let lower, let upper, let negative):
            return try render(.between(operand, lower, upper, negated: !negative))
        case .inList(let operand, let items, let negative):
            return try render(.inList(operand, items, negated: !negative))
        default: break
        }
        return try "(not " + render(value) + ")"
    }
}
