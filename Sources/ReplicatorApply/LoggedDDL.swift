import Foundation
import MySQLSyntax
import ReplicatorCodec

/// This view is only for parsing. Original Query bytes remain the target SQL.
enum LoggedDDL {
    static let commentRule = "target-version-executable-comments"
    static func parsingView(_ query: QueryControl, targetVersion: Int) throws -> QueryControl {
        guard query.sql.range(of: Data("/*!".utf8)) != nil else { return query }
        let context = try query.statusVariables.isEmpty ? nil : QuerySessionContext(query: query)
        let client = context.flatMap { CharacterSetRegistry.collation(id: $0.clientCharset)?.characterSet } ?? "utf8mb4"
        do {
            let sql = try SQLExecutableComments.parsingView(
                query.sql, serverVersion: targetVersion,
                sqlMode: context?.sqlMode ?? 0, characterSet: client)
            return query.replacingSQL(sql)
        } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
    }
    static func versionID(_ text: String) throws -> Int {
        let parts = text.split(separator: ".")
        guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
            let patch = Int(parts[2].prefix(while: { $0.isNumber })),
            (0...99).contains(major), (0...99).contains(minor), (0...99).contains(patch)
        else { throw ApplyError("invalid target version: " + text) }
        return major * 10000 + minor * 100 + patch
    }
}
