import Foundation

/// One lexer for DDL classification and expressions. Quoting follows the logged
/// SQL mode; comments cannot smuggle executable version-specific SQL.
struct DDLToken: Equatable {
    let text: String
    var identifier = false
    var literal: String? = nil
    var range: Range<Int>? = nil
    static func == (lhs: Self,rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.identifier == rhs.identifier && lhs.literal == rhs.literal
    }
    var keyword: String { identifier || literal != nil ? "" : text.uppercased() }
}

enum DDLTokens {
    static func requiresConnectionCollation(_ tokens: [DDLToken]) -> Bool {
        for (i,token) in tokens.enumerated() {
            if ["AS","PROCEDURE","FUNCTION","VIEW"].contains(token.keyword) { return true }
            if let literal=token.literal {
                let engineOption = i > 0 && (tokens[i-1].keyword == "ENGINE" || (i > 1 && tokens[i-1].keyword == "=" && tokens[i-2].keyword == "ENGINE"))
                if !engineOption || !["MYISAM","DEFAULT"].contains(literal.uppercased()) { return true }
            }
        }
        return false
    }
    static func lex(_ data: Data, sqlMode: UInt64 = 0) throws -> [DDLToken] {
        try require(data.count <= 65536, "DDL statement exceeds 64 KiB")
        guard let sql = String(data:data,encoding:.utf8) else { throw ApplyError("invalid DDL UTF-8") }
        let b = Array(sql.utf8)
        var i = 0, result: [DDLToken] = []
        while i < b.count {
            let c = b[i]
            if [9,10,13,32].contains(c) { i += 1; continue }
            if c == 47 && i+1 < b.count && b[i+1] == 42 {
                try require(i+2 < b.count && b[i+2] != 33, "executable DDL comments are unsupported")
                i += 2
                while i+1 < b.count && !(b[i] == 42 && b[i+1] == 47) { i += 1 }
                try require(i+1 < b.count, "unterminated DDL comment"); i += 2; continue
            }
            if c == 35 || (c == 45 && i+2 < b.count && b[i+1] == 45 && b[i+2] <= 32) {
                while i < b.count && b[i] != 10 { i += 1 }; continue
            }
            let start = i
            if c == 96 || c == 39 || c == 34 {
                let isIdentifier = c == 96 || (c == 34 && sqlMode & 4 != 0)
                i += 1; var value: [UInt8] = []; var closed = false
                while i < b.count {
                    if b[i] == c {
                        if i+1 < b.count && b[i+1] == c { value.append(c); i += 2; continue }
                        i += 1; closed = true; break
                    }
                    if b[i] == 92 && !isIdentifier && sqlMode & (1 << 20) == 0 {
                        i += 1; try require(i < b.count, "truncated DDL escape")
                        if b[i] == 37 || b[i] == 95 { value.append(92) }
                        value.append([UInt8(48):0,98:8,110:10,114:13,116:9,90:26][b[i]] ?? b[i]); i += 1
                    } else { value.append(b[i]); i += 1 }
                }
                try require(closed, "unterminated DDL quote")
                guard let decoded = String(bytes:value,encoding:.utf8) else { throw ApplyError("invalid DDL literal encoding") }
                if isIdentifier { _ = try quoted(decoded); result.append(DDLToken(text:decoded,identifier:true)) }
                else { result.append(DDLToken(text:"'"+decoded.replacingOccurrences(of:"'",with:"''")+"'",literal:decoded)) }
            } else if word(c) {
                let start = i; i += 1
                while i < b.count && word(b[i]) { i += 1 }
                result.append(DDLToken(text:String(decoding:b[start..<i],as:UTF8.self)))
            } else {
                try require(c < 128 && "(),.;=+-*/%@<>!|&^~:?".utf8.contains(c), "unsupported DDL token")
                var text = String(UnicodeScalar(c)); i += 1
                if i < b.count && ["<=",">=","!=","<>","<<",">>","||","&&",":="].contains(text+String(UnicodeScalar(b[i]))) {
                    text += String(UnicodeScalar(b[i])); i += 1
                }
                result.append(DDLToken(text:text))
            }
            result[result.count-1].range = start..<i
            try require(result.count <= 16384, "DDL token limit exceeded")
        }
        return result
    }
    static func word(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36
    }
}

/// A deliberately deterministic, target-5.7 expression subset. Canonical AST
/// spelling equates MySQL's added parentheses/backticks without losing grouping.
enum DDLExpression {
    static func canonical(_ sql: String) throws -> String {
        try canonical(DDLTokens.lex(Data(sql.utf8),sqlMode:1 << 20))
    }
    static func canonical(_ tokens: [DDLToken]) throws -> String {
        var parser = ExpressionParser(tokens:tokens)
        let value = try parser.expression()
        try require(parser.i == tokens.count,"unsupported generated/partition expression")
        return value
    }
}
private struct ExpressionParser {
    let tokens: [DDLToken]
    var i = 0
    let precedence = ["OR":1,"AND":2,"=":3,"!=":3,"<>":3,"<":3,">":3,"<=":3,">=":3,"+":4,"-":4,"*":5,"/":5,"DIV":5,"%":5,"MOD":5]
    mutating func expression(_ minimum: Int = 0) throws -> String {
        try require(i < tokens.count,"missing generated/partition expression")
        let token = tokens[i]; i += 1
        var lhs: String
        if token.keyword == "(" {
            lhs = try expression(); try close()
        } else if ["+","-","NOT","~"].contains(token.keyword) {
            lhs = "("+token.keyword.lowercased()+" "+(try expression(6))+")"
        } else if let literal = token.literal {
            lhs = "'"+literal.replacingOccurrences(of:"'",with:"''")+"'"
        } else if token.text.utf8.allSatisfy({(48...57).contains($0)}) && !token.identifier {
            lhs = token.text
            if i+1 < tokens.count && tokens[i].keyword == "." && tokens[i+1].text.utf8.allSatisfy({(48...57).contains($0)}) {
                lhs += "."+tokens[i+1].text; i += 2
            }
        } else if i < tokens.count && tokens[i].keyword == "(" {
            let function = token.keyword.lowercased()
            try require(["abs","ceil","ceiling","floor","round","mod","if","ifnull","nullif","coalesce","concat","concat_ws","lower","upper","length","char_length","character_length","year","month","day","dayofmonth","to_days","to_seconds","datediff","date","hour","minute","second"].contains(function),"unsupported generated/partition function: "+token.text)
            i += 1; var arguments: [String] = []
            repeat {
                arguments.append(try expression())
                if i < tokens.count && tokens[i].keyword == "," { i += 1 } else { break }
            } while true
            try close(); lhs = function+"("+arguments.joined(separator:",")+")"
        } else if ["NULL","TRUE","FALSE"].contains(token.keyword) { lhs = token.keyword.lowercased() }
        else {
            try require(token.identifier || token.text.utf8.allSatisfy(DDLTokens.word),"unsupported expression operand")
            lhs = try quoted(token.text)
        }
        while i < tokens.count, let level = precedence[tokens[i].keyword], level >= minimum {
            let op = tokens[i].keyword.lowercased(); i += 1
            lhs = "("+lhs+" "+op+" "+(try expression(level+1))+")"
        }
        return lhs
    }
    mutating func close() throws {
        try require(i < tokens.count && tokens[i].keyword == ")","unbalanced expression")
        i += 1
    }
}
