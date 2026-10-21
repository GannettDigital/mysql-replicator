/// Fixed labels only. Never put SQL text, literals, or bindings into debug logs.
enum TargetQueryPurpose {
    static func classify(_ sql: String, mutation: Bool) -> String {
        if mutation { return "target_write" }
        let prefix = String(sql.prefix(4096)).uppercased()
        for table in [
            "COLUMNS", "STATISTICS", "TABLES", "SCHEMATA", "PARTITIONS", "KEY_COLUMN_USAGE", "REFERENTIAL_CONSTRAINTS",
            "TRIGGERS", "COLLATIONS", "CHARACTER_SETS", "USER_PRIVILEGES", "SCHEMA_PRIVILEGES", "TABLE_PRIVILEGES",
        ] {
            if prefix.contains("INFORMATION_SCHEMA." + table) { return "schema." + table.lowercased() }
        }
        if prefix.contains("INFORMATION_SCHEMA.") { return "schema_metadata" }
        if prefix.contains("PERFORMANCE_SCHEMA.") { return "replication_metadata" }
        if prefix.hasPrefix("SET ") { return "session_setup" }
        if prefix.hasPrefix("COMMIT") || prefix.hasPrefix("ROLLBACK") || prefix.hasPrefix("BEGIN") {
            return "transaction_control"
        }
        if prefix.hasPrefix("LOCK ") || prefix.hasPrefix("UNLOCK ") { return "table_lock" }
        if prefix.hasPrefix("SELECT ") || prefix.hasPrefix("SHOW ") { return "target_metadata" }
        return "target_setup"
    }
}
