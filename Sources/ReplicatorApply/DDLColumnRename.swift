import Foundation
import MySQLNIO
import MySQLSyntax
import NIOCore
import ReplicatorCodec

extension TargetSession {
    func prepareColumnRenames(_ statement: DDLStatement, source: QueryControl, timestamp: UInt64?, tokens: [DDLToken]?)
        throws -> PreparedDDL
    {
        guard case .alter(let name, _) = statement else { throw ApplyError("column rename requires ALTER") }
        let context = try QuerySessionContext(query: source)
        var parser = try DDLParser(query: source, tokens: try tokens ?? ddlTokens(source))
        parser.nativeRules = NativeReplicationRules(profile: config.replicationProfile)
        parser.engine = contract.engine
        parser.targetVersion = contract.versionPrefix
        parser.lowerCaseTableNames = config.source.tableNameCaseSetting
        _ = try parser.parse()
        let table = try checkedDDLSchema(name)
        let definition: Data = try withMetadataMode(String(contract.ddlSQLMode(context.sqlMode))) {
            _ = try query("SET SESSION sql_quote_show_create=1")
            guard
                let bytes = try query("SHOW CREATE TABLE " + name.sql, textProtocol: true).0.first?.column(
                    "Create Table")?.buffer
            else { throw ApplyError("missing column definition for RENAME COLUMN") }
            return Data(bytes.readableBytesView)
        }
        let columns = try Self.renameColumnSlices(definition, sqlMode: context.sqlMode)
        guard let client = CharacterSetRegistry.collation(id: context.clientCharset)?.characterSet else {
            throw ApplyError("unknown column rename client charset")
        }
        var rewritten = source.sql
        for rename in parser.columnRenames.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard let slice = columns.first(where: { SQLIdentifier.equal($0.name, rename.old) }),
                let column = table.columns.first(where: { SQLIdentifier.equal($0.name, rename.old) }),
                let tail = String(data: definition[slice.definition], encoding: .utf8)
            else { throw ApplyError("missing or invalid native column definition for RENAME COLUMN: " + rename.old) }
            let sql =
                "CHANGE COLUMN " + (try quoted(rename.old)) + " " + (try quoted(rename.new))
                + (try Self.renameColumnDefinition(tail, column: column, sqlMode: context.sqlMode))
            var bytes = Data(sql.utf8)
            if !["utf8mb3", "utf8mb4"].contains(client) {
                let server: CharacterSetRegistry.Server = contract.versionPrefix == "5.7." ? .mysql57 : .mysql84
                let charset = CharacterSetRegistry.charsetName(client, on: server)
                let rows = try query(
                    "SELECT CAST(v AS BINARY) AS raw_value,CONVERT(v USING utf8mb4) AS text_value FROM (SELECT CONVERT(CONVERT(? USING utf8mb4) USING "
                        + charset + ") AS v) AS encoded", [MySQLData(type: .blob, buffer: ByteBuffer(bytes: bytes))]
                ).0
                guard let row = rows.first, let value = row.column("raw_value")?.buffer,
                    row.column("text_value")?.string.map({ SQLTextBytes.equal($0, sql) }) == true
                else {
                    throw ApplyError(
                        "native column definition cannot be represented in the source client charset for RENAME COLUMN")
                }
                bytes = Data(value.readableBytesView)
            }
            rewritten.replaceSubrange(rename.range, with: bytes)
        }
        let translatedQuery = source.replacingSQL(rewritten)
        let translatedTokens = try ddlTokens(translatedQuery)
        let parsed = try DDLStatement.parse(
            translatedQuery, profile: config.replicationProfile, tokens: translatedTokens,
            lowerCaseTableNames: config.source.tableNameCaseSetting)
        var plan = try prepareDDL(parsed, query: translatedQuery, timestamp: timestamp, tokens: translatedTokens)
        plan.compatibilityRules.append("rename-column-using-native-definition")
        return plan
    }
    static func renameColumnSlices(_ definition: Data, sqlMode: UInt64) throws -> [SQLTableColumnSlice] {
        // SHOW CREATE wraps partition clauses in version comments. This mode
        // reads trusted server metadata; source DDL keeps its separate gate.
        try SQLTableDefinition.columns(DDLTokens.lex(definition, sqlMode: sqlMode, nativeMetadata: true))
    }
    static func renameColumnDefinition(_ tail: String, column: ApplyColumn, sqlMode: UInt64) throws -> String {
        guard let charset = column.characterSet, let collation = column.collation else { return tail }
        let tokens = try DDLTokens.lex(Data(tail.utf8), sqlMode: sqlMode)
        var depth = 0
        var words: [DDLToken] = []
        for token in tokens {
            if token.keyword == "(" { depth += 1 }
            if token.keyword == ")" {
                depth -= 1
                continue
            }
            if depth == 0 { words.append(token) }
        }
        var encoding = ""
        if !words.contains(where: { $0.keyword == "CHARACTER" }) {
            encoding += " CHARACTER SET " + (try quoted(charset))
        }
        if !words.contains(where: { $0.keyword == "COLLATE" }) { encoding += " COLLATE " + (try quoted(collation)) }
        guard !encoding.isEmpty else { return tail }
        // Native grammar puts charset before column attributes, including COLLATE.
        var end = 1
        if tokens.count > end && tokens[end].keyword == "(" {
            var nesting = 0
            repeat {
                if tokens[end].keyword == "(" { nesting += 1 }
                if tokens[end].keyword == ")" { nesting -= 1 }
                end += 1
            } while end < tokens.count && nesting > 0
        }
        // A native CHARACTER SET clause can be present without COLLATE.
        // Insert the missing collation after that clause, not before it.
        if let character = tokens.indices.first(where: { tokens[$0].keyword == "CHARACTER" }),
            character + 2 < tokens.count
        {
            end = character + 3
        }
        guard end > 0, let offset = tokens[end - 1].range?.upperBound else {
            throw ApplyError("missing native column type range")
        }
        var bytes = Data(tail.utf8)
        bytes.insert(contentsOf: encoding.utf8, at: offset)
        return String(decoding: bytes, as: UTF8.self)
    }

}
