import Foundation

/// Read stored defaults from the server. Reuse each metadata row only within
/// this comparison; the next source statement can change the definition.
enum LabStoredDefaultComparison {
    static func columns(
        _ columns: [[String]], database: String,
        execute: ([LabSQLBatch.Query]) throws -> [String: String]
    ) throws -> [[String]] {
        var result = columns
        var pending: [(index: Int, query: LabSQLBatch.Query)] = []
        var pendingBytes = 0
        let maximumQueries = 32
        let maximumSQLBytes = 256 * 1024
        func flush() throws {
            guard !pending.isEmpty else { return }
            let values = try execute(pending.map(\.query))
            try require(
                Set(values.keys) == Set(pending.map { $0.query.name }),
                "stored default batch results differ")
            for item in pending {
                let bytes = values[item.query.name]!
                try require(
                    bytes.utf8.count % 2 == 0
                        && bytes.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) },
                    "invalid native stored default bytes")
                result[item.index][7] = "X'" + bytes + "'"
            }
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
        }
        for (index, fields) in columns.enumerated()
        where fields.count == 10 && fields[7] == "<stored-default>" {
            let query = LabSQLBatch.Query(
                name: "default-\(index)", sql: "SET NAMES utf8mb4; " + query(fields, database: database),
                preserveWhitespace: true)
            let bytes = query.sql.utf8.count
            if !pending.isEmpty && pendingBytes + bytes > maximumSQLBytes { try flush() }
            pending.append((index, query))
            pendingBytes += bytes
            if pending.count == maximumQueries || pendingBytes >= maximumSQLBytes { try flush() }
        }
        try flush()
        return result
    }

    private static func query(_ fields: [String], database: String) -> String {
        let table = LabSQLName.quote(database) + "." + LabSQLName.quote(fields[0])
        let column = LabSQLName.quote(fields[1])
        let text = fields[3].hasPrefix("char(") || fields[3].hasPrefix("varchar(")
        if fields[4] == "NO" {
            // DEFAULT on a null-complemented NOT NULL field is NULL. Copy the
            // native definition, not its rows. The client session owns the clone.
            let temporary =
                LabSQLName.quote(database) + "."
                + LabSQLName.quote(
                    "_lab_default_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            let value = text ? "CONVERT(v USING utf8mb4)" : "v"
            return "SET sql_log_bin=0; CREATE TEMPORARY TABLE " + temporary + " ENGINE=InnoDB AS SELECT "
                + column + " AS v FROM " + table + " LIMIT 0; INSERT INTO " + temporary
                + " VALUES(DEFAULT); SELECT HEX(" + value + ") FROM " + temporary
                + "; DROP TEMPORARY TABLE " + temporary
        }
        let stored = "DEFAULT(t." + column + ")"
        let expression = text ? "CONVERT(" + stored + " USING utf8mb4)" : stored
        return "SELECT HEX(" + expression + ") FROM " + table
            + " AS t RIGHT JOIN (SELECT 1) AS p ON FALSE LIMIT 1"
    }
}
