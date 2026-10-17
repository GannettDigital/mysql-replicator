import Foundation

/// STATISTICS has no parser-plugin column. Read that attribute from the native
/// SHOW CREATE result. Quoted names and literals cannot act as SQL keywords.
enum FulltextMetadata {
    struct Index { let parser:String? }
    static func parsers(_ sql:Data) throws -> [SQLNameKey:Index] {
        let tokens=try DDLTokens.lex(sql,sqlMode:1 << 20,nativeMetadata:true)
        var result:[SQLNameKey:Index]=[:],i=0,depth=0
        while i < tokens.count {
            if tokens[i].keyword == "(" { depth += 1 }
            if tokens[i].keyword == ")" { depth -= 1 }
            if depth == 1 && tokens[i].keyword == "FULLTEXT" {
                try require(i+3 < tokens.count && ["KEY","INDEX"].contains(tokens[i+1].keyword),"invalid native FULLTEXT definition")
                let name=SQLIdentifier.key(tokens[i+2].text)
                var j=i+3,partDepth=0,parser:String?
                while j < tokens.count {
                    let token=tokens[j]
                    if partDepth == 0 && [",",")"].contains(token.keyword) { break }
                    if token.keyword == "(" { partDepth += 1 }
                    else if token.keyword == ")" { partDepth -= 1 }
                    else if partDepth == 0 && token.keyword == "WITH" {
                        try require(j+2 < tokens.count && tokens[j+1].keyword == "PARSER" && parser == nil,"invalid native FULLTEXT parser")
                        parser=SQLIdentifier.lowercase(tokens[j+2].text);_ = try quoted(parser!);j += 2
                    }
                    j += 1
                }
                try require(result[name] == nil,"duplicate native FULLTEXT index")
                result[name]=Index(parser:parser);i=j;continue
            }
            i += 1
        }
        return result
    }
}
