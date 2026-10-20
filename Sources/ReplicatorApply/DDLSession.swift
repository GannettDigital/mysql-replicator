import Foundation
import ReplicatorCodec

extension TargetSession {
    func setDDLSession(_ context: QuerySessionContext, source: QueryControl, useDatabase: Bool = true) throws {
        _ = try query(
            "SET SESSION sql_mode=\(contract.ddlSQLMode(context.sqlMode)),auto_increment_increment=\(context.autoIncrementIncrement),auto_increment_offset=\(context.autoIncrementOffset)"
        )
        // A named zone must exist on the target too; no timezone substitution.
        _ = try query("SET SESSION time_zone=?", [.init(string: context.timeZone ?? "+00:00")])
        try require(context.explicitDefaultsForTimestamp != false, "legacy implicit TIMESTAMP defaults are unsupported")
        _ = try query("SET SESSION explicit_defaults_for_timestamp=1")
        // USE contains names from the UTF-8 schema model, not source SQL bytes.
        _ = try query("SET NAMES utf8mb4 COLLATE utf8mb4_bin")
        if useDatabase, let db = source.database, !db.isEmpty { _ = try query("USE \(quoted(db))", textProtocol: true) }
        // Q_CHARSET identifies character_set_client by a collation ID. Source
        // ID 255 (8.x's utf8mb4 default) still means utf8mb4 bytes on 5.7, where
        // ID 45 identifies that encoding. This does not substitute the separate
        // connection collation used for expressions, checked below.
        let clientEncodingID = CharacterSetRegistry.clientEncodingID(
            context.clientCharset,
            target: contract.versionPrefix == "5.7." ? .mysql57 : .mysql84)
        let charset = try query(
            "SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE ID=?",
            [.init(string: String(clientEncodingID))]
        ).0.first
        guard let client = charset?.column("CHARACTER_SET_NAME")?.string else {
            throw ApplyError(
                "unsupported DDL client charset: character_set_client=\(DDLQueryContextDiagnostic.collation(context.clientCharset))"
            )
        }
        _ = try query("SET SESSION character_set_client=?", [.init(string: client)])
        if let collation = try scalar(
            "SELECT COLLATION_NAME AS v FROM information_schema.COLLATIONS WHERE ID=?",
            [.init(string: String(config.compatibilityPolicy.targetID(context.connectionCollation)))])
        {
            _ = try query("SET SESSION collation_connection=?", [.init(string: collation)])
        } else {
            // Existing ASCII-only table DDL does not depend on expression
            // collation. Anything introducing literals/expressions must reject.
            let tokens = try ddlTokens(source)
            try require(
                !DDLTokens.requiresConnectionCollation(tokens),
                "source expression collation is unavailable on MySQL 5.7: collation_connection=\(DDLQueryContextDiagnostic.collation(context.connectionCollation))",
                code: .unsupportedCollation)
        }
    }
    func prepareDropDatabase(
        _ statement: DDLStatement, name: String, conditional: Bool, source: QueryControl, context: QuerySessionContext
    ) throws -> PreparedDDL {
        let exists =
            try scalar(
                "SELECT COUNT(*) AS v FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?", [.init(string: name)])
            != "0"
        try require(exists || conditional, "DDL DROP DATABASE target is absent")
        let before = exists ? try databaseEncoding(name) : nil
        var retired = discovered.filter { SQLTextBytes.equal($0.value.database, name) }
        if contract.transactional && exists {
            try requireForeignKeyVisibility()
            // Include every FK participant in this database, even if no row
            // event has loaded it. The graph planner also loads outside tables.
            let rows = try query(
                "SELECT DISTINCT BINARY TABLE_NAME AS name FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=? AND REFERENCED_TABLE_NAME IS NOT NULL UNION SELECT DISTINCT BINARY REFERENCED_TABLE_NAME AS name FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY REFERENCED_TABLE_SCHEMA=? AND REFERENCED_TABLE_NAME IS NOT NULL",
                [.init(string: name), .init(string: name)]
            ).0
            for row in rows {
                guard let table = row.column("name")?.string else {
                    throw ApplyError("missing DROP DATABASE relationship table")
                }
                guard try tableExists(TableName(database: name, table: table)) else { continue }
                let schema = try readSchema(database: name, name: table)
                if let known = discovered[schema.identity] {
                    try require(known == schema, "target schema drift before DROP DATABASE")
                }
                retired[schema.identity] = schema
                try require(retired.count <= maximumCachedTables, "DROP DATABASE schema limit exceeded")
            }
        }
        // Record each affected FK participant, including tables not yet used by
        // a row event. Retire these snapshots with the database's source GTID.
        let changes = retired.keys.sorted().map { SchemaTransition(before: retired[$0], after: nil) }
        let plan = try prepareForeignKeyTransitions(
            PreparedDDL(
                statement: statement, before: nil, after: nil, sql: String(decoding: source.sql, as: UTF8.self),
                database: PreparedDatabaseDDL(name: name, before: before, after: nil, serverCollation: nil),
                additional: changes), foreignKeyChecks: context.foreignKeyChecks)
        try setDDLSession(context, source: source, useDatabase: false)
        return plan
    }
}
