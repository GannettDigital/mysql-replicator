import Foundation

/// One lexer for DDL classification and expressions. Quoting follows the logged
/// SQL mode; comments cannot smuggle executable version-specific SQL.
struct DDLToken: Equatable {
    let text: String
    var identifier = false
    var literal: String? = nil
    var literalBytes: Data? = nil
    var range: Range<Int>? = nil
    static func == (lhs: Self,rhs: Self) -> Bool {
        SQLTextBytes.equal(lhs.text,rhs.text) && lhs.identifier == rhs.identifier && SQLTextBytes.equal(lhs.literal,rhs.literal) && lhs.literalBytes == rhs.literalBytes
    }
    var keyword: String { identifier || literal != nil ? "" : SQLIdentifier.keyword(text) }
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
    static func lex(_ data: Data, sqlMode: UInt64 = 0, characterSet: String = "utf8mb4", nativeMetadata:Bool = false,
                    decode: ((Data,Bool) throws -> DDLDecodedText)? = nil) throws -> [DDLToken] {
        try require(data.count <= 65536, "DDL statement exceeds 64 KiB")
        if decode == nil { try require(String(data:data,encoding:.utf8) != nil,"invalid DDL UTF-8") }
        func decoded(_ bytes: [UInt8], identifier: Bool) throws -> DDLDecodedText {
            if let decode { return try decode(Data(bytes),identifier) }
            guard let text=String(bytes:bytes,encoding:.utf8) else { throw ApplyError("invalid DDL literal encoding") }
            return DDLDecodedText(text:text,bytes:nil)
        }
        let b = Array(data)
        var i = 0, result: [DDLToken] = []
        while i < b.count {
            let c = b[i]
            if [9,10,13,32].contains(c) { i += 1; continue }
            if c == 47 && i+1 < b.count && b[i+1] == 42 {
                let executable=i+2 < b.count && b[i+2] == 33
                try require(!executable || nativeMetadata,"executable DDL comments are unsupported")
                i += 2;var content=i
                if executable {
                    content += 1
                    while content < b.count && (48...57).contains(b[content]) { content += 1 }
                }
                while i+1 < b.count && !(b[i] == 42 && b[i+1] == 47) { i += 1 }
                try require(i+1 < b.count,"unterminated DDL comment")
                // Only SHOW CREATE metadata opts in. Source SQL keeps its strict
                // version-comment gate; metadata tokens are never executed.
                if executable { result += try lex(Data(b[content..<i]),sqlMode:sqlMode) }
                try require(result.count <= 16384,"DDL token limit exceeded")
                i += 2;continue
            }
            if c == 35 || (c == 45 && i+2 < b.count && b[i+1] == 45 && b[i+2] <= 32) {
                while i < b.count && b[i] != 10 { i += 1 }; continue
            }
            let start = i
            if c == 96 || c == 39 || c == 34 {
                let isIdentifier = c == 96 || (c == 34 && sqlMode & 4 != 0)
                i += 1; var value: [UInt8] = []; var closed = false
                while i < b.count {
                    let width=DDLClientEncoding.characterWidth(b,at:i,charset:characterSet)
                    if width > 1 { value.append(contentsOf:b[i..<i+width]);i += width;continue }
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
                let converted = try decoded(value,identifier:isIdentifier)
                if isIdentifier { let name=SQLIdentifier.storedName(converted.text); _ = try quoted(name); result.append(DDLToken(text:name,identifier:true)) }
                else { result.append(DDLToken(text:"'"+converted.text.replacingOccurrences(of:"'",with:"''")+"'",literal:converted.text,literalBytes:converted.bytes)) }
            } else if word(c) {
                let start = i
                repeat { i += DDLClientEncoding.characterWidth(b,at:i,charset:characterSet) } while i < b.count && word(b[i])
                let text=try decoded(Array(b[start..<i]),identifier:true).text,name=SQLIdentifier.storedName(text)
                result.append(DDLToken(text:name,identifier:!SQLTextBytes.equal(text,name)))
            } else {
                try require(c < 128 && "(),.;=+-*/%@<>!|&^~:?".utf8.contains(c), "unsupported DDL token")
                var text = String(UnicodeScalar(c)); i += 1
                if i < b.count && ["<=",">=","!=","<>","<<",">>","||","&&",":=","->"].contains(text+String(UnicodeScalar(b[i]))) {
                    text += String(UnicodeScalar(b[i])); i += 1
                    if text == "->" && i < b.count && b[i] == 62 { text += ">";i += 1 }
                }
                result.append(DDLToken(text:text))
            }
            result[result.count-1].range = start..<i
            try require(result.count <= 16384, "DDL token limit exceeded")
        }
        return result
    }
    static func word(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36 || c >= 128
    }
}

/// Canonical expressions for schema comparison; SQL still runs on the target. Canonical AST
/// spelling equates MySQL's added parentheses/backticks without losing grouping.
enum DDLExpression {
    static func references(_ name:String,in expression:String) throws -> Bool {
        try DDLTokens.lex(Data(expression.utf8),sqlMode:1 << 20).contains { $0.identifier && SQLIdentifier.equal($0.text,name) }
    }
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
    let precedence = ["OR":1,"AND":2,"=":3,"!=":3,"<>":3,"<":3,">":3,"<=":3,">=":3,"+":4,"-":4,"*":5,"/":5,"DIV":5,"%":5,"MOD":5,"->":7,"->>":7,"COLLATE":8]
    mutating func expression(_ minimum: Int = 0) throws -> String {
        try require(i < tokens.count,"missing generated/partition expression")
        let token = tokens[i]; i += 1
        var lhs: String
        if token.keyword == "(" {
            lhs = try expression(); try close()
        } else if ["+","-","NOT","~"].contains(token.keyword) {
            lhs = "("+token.keyword.lowercased()+" "+(try expression(6))+")"
        } else if token.keyword.hasPrefix("_"), i < tokens.count, tokens[i].literal != nil {
            let literal=try expression(8)
            // The lexer already stores UTF-8 text. MySQL 8.4 adds this introducer
            // when it prints the same UTF-8 literal from a 5.7 expression.
            lhs = token.keyword == "_UTF8MB4" ? literal : token.keyword.lowercased()+literal
        } else if let literal = token.literal {
            lhs = "'"+literal.replacingOccurrences(of:"'",with:"''")+"'"
        } else if token.text.utf8.allSatisfy({(48...57).contains($0)}) && !token.identifier {
            lhs = token.text
            if i+1 < tokens.count && tokens[i].keyword == "." && tokens[i+1].text.utf8.allSatisfy({(48...57).contains($0)}) {
                lhs += "."+tokens[i+1].text; i += 2
            }
        } else if i < tokens.count && tokens[i].keyword == "(" {
            let function = token.keyword.lowercased()
            if function == "cast" {
                i += 1
                let value=try expression()
                try require(i < tokens.count && tokens[i].keyword == "AS","missing CAST type");i += 1
                try require(i < tokens.count,"missing CAST type")
                var type=tokens[i].keyword.lowercased();i += 1
                try require(["char","binary","signed","unsigned","decimal","date","datetime","time","json","float","double","real"].contains(type),"unsupported CAST type")
                if ["signed","unsigned"].contains(type), i < tokens.count, tokens[i].keyword == "INTEGER" { i += 1 }
                if i < tokens.count && tokens[i].keyword == "(" {
                    i += 1;var sizes:[String]=[]
                    repeat {
                        try require(i < tokens.count && !tokens[i].text.isEmpty && tokens[i].text.utf8.allSatisfy { (48...57).contains($0) },"invalid CAST width")
                        sizes.append(tokens[i].text);i += 1
                        if i < tokens.count && tokens[i].keyword == "," { i += 1 } else { break }
                    } while true
                    try close();type += "("+sizes.joined(separator:",")+")"
                }
                if i < tokens.count && ["CHARSET","CHARACTER"].contains(tokens[i].keyword) {
                    let long=tokens[i].keyword == "CHARACTER";i += 1
                    if long { try require(i < tokens.count && tokens[i].keyword == "SET","missing CAST CHARACTER SET");i += 1 }
                    try require(i < tokens.count && tokens[i].text.utf8.allSatisfy(DDLTokens.word),"missing CAST charset")
                    let charset=tokens[i].text.lowercased();i += 1
                    if charset != "utf8mb4" { type += " charset "+charset }
                }
                try close();lhs="cast("+value+" as "+type+")"
            } else {
                try require(["abs","ceil","ceiling","floor","round","mod","if","ifnull","nullif","coalesce","concat","concat_ws","lower","upper","length","char_length","character_length","year","month","day","dayofmonth","to_days","to_seconds","datediff","date","hour","minute","second","json_extract","json_unquote","json_quote","json_object","json_array","json_length","json_type","json_valid","json_contains","json_contains_path","json_keys","json_depth","json_set","json_insert","json_replace","json_remove","json_merge_preserve","json_merge_patch","json_array_append","json_array_insert"].contains(function),"unsupported generated/partition function: "+token.text)
                i += 1; var arguments: [String] = []
                while i < tokens.count && tokens[i].keyword != ")" {
                    arguments.append(try expression())
                    if i < tokens.count && tokens[i].keyword == "," {
                        i += 1;try require(i < tokens.count && tokens[i].keyword != ")","missing function argument")
                    } else { break }
                }
                try close(); lhs = function+"("+arguments.joined(separator:",")+")"
            }
        } else if ["NULL","TRUE","FALSE"].contains(token.keyword) { lhs = token.keyword.lowercased() }
        else {
            try require(token.identifier || token.text.utf8.allSatisfy(DDLTokens.word),"unsupported expression operand")
            lhs = try quoted(token.text)
        }
        while i < tokens.count, let level = precedence[tokens[i].keyword], level >= minimum {
            let op = tokens[i].keyword.lowercased(); i += 1
            if op == "collate" {
                try require(i < tokens.count && tokens[i].literal == nil && tokens[i].text.utf8.allSatisfy(DDLTokens.word),"missing expression collation")
                lhs="("+lhs+" collate "+tokens[i].text.lowercased()+")";i += 1;continue
            }
            let rhs=try expression(level+1)
            if op == "->" || op == "->>" {
                lhs="json_extract("+lhs+","+rhs+")"
                if op == "->>" { lhs="json_unquote("+lhs+")" }
            } else { lhs = "("+lhs+" "+op+" "+rhs+")" }
        }
        return lhs
    }
    mutating func close() throws {
        try require(i < tokens.count && tokens[i].keyword == ")","unbalanced expression")
        i += 1
    }
}
