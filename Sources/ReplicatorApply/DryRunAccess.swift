import Foundation

struct DryRunUnresolved: Error, CustomStringConvertible {
    let description: String
    init(_ detail: String) { description = detail }
}

/// Defense at the connection boundary. Preview code has no writer capability.
enum DryRunAccess {
    static func check(_ sql: String, mutation: Bool, rawSQL: Data?) throws {
        let text = sql.uppercased()
        let metadata =
            text.hasPrefix("SELECT ")
            && (text.contains("FROM INFORMATION_SCHEMA.") || text.contains("FROM PERFORMANCE_SCHEMA.")
                || text.hasPrefix("SELECT @@") || text.hasPrefix("SELECT VERSION()")
                || text.hasPrefix("SELECT CONVERT(V USING UTF8MB4) AS TEXT_VALUE,"))
        let show = [
            "SHOW SESSION STATUS ", "SHOW SLAVE STATUS", "SHOW REPLICA STATUS", "SHOW CREATE TABLE ",
            "SHOW CREATE VIEW ", "SHOW ENGINES",
        ].contains { text.hasPrefix($0) }
        guard !mutation, rawSQL == nil, metadata || show,
            !text.contains("GET_LOCK("), !text.contains("INTO OUTFILE"), !text.contains("INTO DUMPFILE"),
            !text.contains("FOR UPDATE")
        else {
            throw DryRunUnresolved("dry run refused a target operation outside metadata reads")
        }
    }
}
