import Foundation

/// Read each table once, then inspect JSON cells across all tables in bounded
/// batches. Keep row markers until rendering so empty values remain real rows.
enum LabComparisonRows {
    struct Table {
        let name: String
        let columns: [String]
        let jsonColumns: [String]
        let orderBy: String
    }

    static func read(
        database: String, tables: [Table], execute: ([LabSQLBatch.Query]) throws -> [String: String]
    ) throws -> String {
        guard !tables.isEmpty else { return "" }
        let queries = try tables.enumerated().map { index, table -> LabSQLBatch.Query in
            try require(!table.columns.isEmpty, "comparison table has no columns")
            let expressions = table.columns.map {
                "IFNULL(HEX(CAST(" + LabSQLName.quote($0) + " AS BINARY)),'<NULL>')"
            }.joined(separator: ",")
            return .init(
                name: "rows-\(index)",
                sql: "SET NAMES utf8mb4; SET time_zone='+00:00'; SELECT 1," + expressions
                    + " FROM " + LabSQLName.quote(database) + "." + LabSQLName.quote(table.name)
                    + " ORDER BY " + table.orderBy,
                preserveWhitespace: true)
        }
        var raw: [String: String] = [:]
        var pending: [LabSQLBatch.Query] = []
        var bytes = 0
        func flush() throws {
            guard !pending.isEmpty else { return }
            let values = try execute(pending)
            try require(Set(values.keys) == Set(pending.map(\.name)), "comparison raw-row results differ")
            raw.merge(values) { _, new in new }
            pending.removeAll(keepingCapacity: true)
            bytes = 0
        }
        for query in queries {
            let size = query.sql.utf8.count
            if !pending.isEmpty && bytes + size > 256 * 1024 { try flush() }
            pending.append(query)
            bytes += size
            if pending.count == 32 || bytes >= 256 * 1024 { try flush() }
        }
        try flush()
        let inputs = try tables.enumerated().map { index, table -> LabJSONComparison.Table in
            let value = raw[queries[index].name]!
            if !value.isEmpty {
                for row in value.components(separatedBy: "\n") {
                    try require(row.hasPrefix("1\t") && row.components(separatedBy: "\t").count == table.columns.count + 1,
                        "comparison raw-row width or marker differs")
                }
            }
            var marker = "__comparison_row__"
            while table.columns.contains(where: { LabSQLName.equal($0, marker) }) { marker += "_" }
            return .init(
                raw: value, columns: [marker] + table.columns, jsonColumns: table.jsonColumns,
                from: " FROM " + LabSQLName.quote(database) + "." + LabSQLName.quote(table.name)
                    + " ORDER BY " + table.orderBy)
        }
        let inspected = try LabJSONComparison.rows(inputs, execute: execute)
        return try inspected.enumerated().flatMap { index, value -> [String] in
            guard !value.isEmpty else { return [] }
            return try value.components(separatedBy: "\n").map { row in
                try require(row.hasPrefix("1\t"), "comparison row marker is missing")
                return tables[index].name + "\t" + String(row.dropFirst(2))
            }
        }.joined(separator: "\n")
    }
}
