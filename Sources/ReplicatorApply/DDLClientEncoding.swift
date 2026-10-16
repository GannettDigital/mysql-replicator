import Foundation
import MySQLSyntax
import ReplicatorCodec
import MySQLNIO
import NIOCore

typealias DDLDecodedText = SQLDecodedText
typealias DDLClientEncoding = SQLClientEncoding

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
