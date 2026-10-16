import ReplicatorCodec

/// Logged source settings for DDL audit and failures. No live source lookup:
/// its current defaults may differ from those in the rejected event.
struct DDLQueryContextDiagnostic: Codable {
    let database: String?
    let clientCharsetID: UInt32
    let connectionCollationID: UInt32
    let serverCollationID: UInt32
    let serverCollationName: String?
    let databaseCollationID: UInt32?
    let defaultUTF8MB4CollationID: UInt32

    var foreignKeyChecks: Bool? = nil
    var autoIncrementIncrement: UInt32? = nil
    var autoIncrementOffset: UInt32? = nil
    var sourceSQLBase64: String? = nil
    var targetSQLBase64: String? = nil
    var nativeCompatibilityRules: [String]? = nil
    var viewTransitions: [ViewTransition]? = nil

    init?(query: QueryControl) {
        guard let context = try? QuerySessionContext(query: query) else { return nil }
        autoIncrementIncrement = context.autoIncrementIncrement
        autoIncrementOffset = context.autoIncrementOffset
        foreignKeyChecks = context.foreignKeyChecks
        database = query.database
        sourceSQLBase64 = query.sql.base64EncodedString()
        clientCharsetID = context.clientCharset
        connectionCollationID = context.connectionCollation
        serverCollationID = context.serverCollation
        serverCollationName = Self.knownCollationName(context.serverCollation)
        databaseCollationID = context.databaseCollation
        defaultUTF8MB4CollationID = context.defaultUTF8MB4Collation
    }

    // Known native identities, not a substitution map.
    // Unknown IDs remain numeric rather than guessing their names.
    static func knownCollationName(_ id: UInt32) -> String? {
        CharacterSetRegistry.collation(id:id)?.diagnosticName
    }
    static func collation(_ id: UInt32) -> String {
        "ID \(id)" + (knownCollationName(id).map { " (\($0))" } ?? "")
    }
}
