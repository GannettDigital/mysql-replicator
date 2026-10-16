import Foundation
import ReplicatorCodec
import MySQLNIO
import NIOCore

struct DDLDecodedText {
    let text: String
    /// Literal bytes after conversion to character_set_connection.
    let bytes: Data?
}

enum DDLClientEncoding {
    /// Native ismbchar boundaries for encodings whose trailing byte can be
    /// ASCII punctuation. Other supported client encodings cannot hide a quote
    /// or backslash in a multibyte character. Native MySQL converts token values.
    static func characterWidth(_ b:[UInt8],at i:Int,charset:String) -> Int {
        guard i+1 < b.count else { return 1 }
        let first=b[i],second=b[i+1]
        switch charset {
        case "sjis","cp932":
            return ((0x81...0x9f).contains(first) || (0xe0...0xfc).contains(first)) && ((0x40...0x7e).contains(second) || (0x80...0xfc).contains(second)) ? 2 : 1
        case "big5":
            return (0xa1...0xf9).contains(first) && ((0x40...0x7e).contains(second) || (0xa1...0xfe).contains(second)) ? 2 : 1
        case "gbk","gb18030":
            guard (0x81...0xfe).contains(first) else { return 1 }
            if (0x40...0xfe).contains(second) && second != 0x7f { return 2 }
            if charset == "gb18030",i+3 < b.count,(0x30...0x39).contains(second),
               (0x81...0xfe).contains(b[i+2]),(0x30...0x39).contains(b[i+3]) { return 4 }
            return 1
        default: return 1
        }
    }
}

extension TargetSession {
    /// Read-only conversion uses the target's native charset tables. This runs
    /// at a DDL barrier, not in the row apply loop. Original SQL stays unchanged.
    func ddlTokens(_ source:QueryControl) throws -> [DDLToken] {
        let context=try QuerySessionContext(query:source)
        guard let client=CharacterSetRegistry.collation(id:context.clientCharset)?.characterSet,
              let connection=CharacterSetRegistry.collation(id:config.compatibilityPolicy.targetID(context.connectionCollation))?.characterSet else {
            throw ApplyError("unknown DDL client or connection encoding")
        }
        try require(!["ucs2","utf16","utf16le","utf32"].contains(client),"native MySQL does not permit this client encoding: "+client)
        if ["utf8mb3","utf8mb4"].contains(client) && connection == "utf8mb4" {
            return try DDLTokens.lex(source.sql,sqlMode:context.sqlMode)
        }
        struct Key:Hashable { let bytes:Data;let identifier:Bool }
        var cache:[Key:DDLDecodedText]=[:]
        let server:CharacterSetRegistry.Server=contract.versionPrefix == "5.7." ? .mysql57 : .mysql84
        return try DDLTokens.lex(source.sql,sqlMode:context.sqlMode,characterSet:client) { bytes,identifier in
            if identifier && bytes.allSatisfy({ $0 < 128 }) { return .init(text:String(decoding:bytes,as:UTF8.self),bytes:nil) }
            let key=Key(bytes:bytes,identifier:identifier)
            if let value=cache[key] { return value }
            let destination=identifier ? CharacterSetRegistry.charsetName("utf8mb3",on:server) : CharacterSetRegistry.charsetName(connection,on:server)
            let from=CharacterSetRegistry.charsetName(client,on:server)
            let expression="CONVERT(CONVERT(? USING "+from+") USING "+destination+")"
            let rows=try self.query("SELECT CONVERT(v USING utf8mb4) AS text_value,CAST(v AS BINARY) AS raw_value FROM (SELECT "+expression+" AS v) AS converted",[MySQLData(type:.blob,buffer:ByteBuffer(bytes:bytes))]).0
            guard let row=rows.first,let text=row.column("text_value")?.string,let raw=row.column("raw_value")?.buffer else { throw ApplyError("native DDL token conversion failed") }
            let value=DDLDecodedText(text:text,bytes:identifier ? nil : Data(raw.readableBytesView))
            cache[key]=value
            return value
        }
    }
}
