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

    init?(query: QueryControl) {
        guard let context = try? QuerySessionContext(query: query) else { return nil }
        database = query.database
        clientCharsetID = context.clientCharset
        connectionCollationID = context.connectionCollation
        serverCollationID = context.serverCollation
        serverCollationName = Self.knownCollationName(context.serverCollation)
        databaseCollationID = context.databaseCollation
        defaultUTF8MB4CollationID = context.defaultUTF8MB4Collation
    }

    // A diagnostic label for the common 8.x default, not a substitution map.
    // Unknown IDs remain numeric rather than guessing their names.
    static func knownCollationName(_ id: UInt32) -> String? {
        id == 255 ? "utf8mb4_0900_ai_ci" : nil
    }
    static func collation(_ id: UInt32) -> String {
        "ID \(id)" + (knownCollationName(id).map { " (\($0))" } ?? "")
    }
}
