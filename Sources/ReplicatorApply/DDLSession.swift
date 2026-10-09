import Foundation
import ReplicatorCodec

extension TargetSession {
    func setDDLSession(_ context: QuerySessionContext,source: QueryControl,useDatabase: Bool = true) throws {
        _ = try query("SET SESSION sql_mode=\(contract.ddlSQLMode(context.sqlMode))")
        // A named zone must exist on the target too; no timezone substitution.
        _ = try query("SET SESSION time_zone=?",[.init(string:context.timeZone ?? "+00:00")])
        try require(context.explicitDefaultsForTimestamp != false,"legacy implicit TIMESTAMP defaults are unsupported")
        _ = try query("SET SESSION explicit_defaults_for_timestamp=1")
        // Q_CHARSET identifies character_set_client by a collation ID. Source
        // ID 255 (8.x's utf8mb4 default) still means utf8mb4 bytes on 5.7, where
        // ID 45 identifies that encoding. This does not substitute the separate
        // connection collation used for expressions, checked below.
        let clientEncodingID = context.clientCharset == 255 ? 45 : context.clientCharset
        let charset = try query("SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE ID=?",[.init(string:String(clientEncodingID))]).0.first
        guard let client = charset?.column("CHARACTER_SET_NAME")?.string else {throw ApplyError("unsupported DDL client charset: character_set_client=\(DDLQueryContextDiagnostic.collation(context.clientCharset))")}
        _ = try query("SET SESSION character_set_client=?",[.init(string:client)])
        if let collation = try scalar("SELECT COLLATION_NAME AS v FROM information_schema.COLLATIONS WHERE ID=?",[.init(string:String(config.compatibilityPolicy.targetID(context.connectionCollation)))]) {
            _ = try query("SET SESSION collation_connection=?",[.init(string:collation)])
        } else {
            // Existing ASCII-only table DDL does not depend on expression
            // collation. Anything introducing literals/expressions must reject.
            let tokens = try DDLTokens.lex(source.sql,sqlMode:context.sqlMode)
            try require(!DDLTokens.requiresConnectionCollation(tokens),"source expression collation is unavailable on MySQL 5.7: collation_connection=\(DDLQueryContextDiagnostic.collation(context.connectionCollation))",code:.unsupportedCollation)
        }
        if useDatabase, let db = source.database, !db.isEmpty { _ = try query("USE \(quoted(db))",textProtocol:true) }
    }
    func prepareDropDatabase(_ statement: DDLStatement,name: String,conditional: Bool,source: QueryControl,context: QuerySessionContext) throws -> PreparedDDL {
        let exists = try scalar("SELECT COUNT(*) AS v FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?",[.init(string:name)]) != "0"
        try require(exists || conditional,"DDL DROP DATABASE target is absent")
        let before = exists ? try databaseEncoding(name) : nil
        // Retire every known table in this database atomically with the GTID.
        // Unseen objects need no invented table-schema records.
        let changes = discovered.values.filter{$0.database == name}.map{SchemaTransition(before:$0,after:nil)}
        try setDDLSession(context,source:source,useDatabase:false)
        return PreparedDDL(statement:statement,before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self),database:PreparedDatabaseDDL(name:name,before:before,after:nil,serverCollation:nil),additional:changes)
    }
}
