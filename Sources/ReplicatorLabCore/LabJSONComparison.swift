import Foundation

/// Use the server's JSON types and scalar values as an independent oracle.
/// Foundation supplies only the paths; it does not convert the numeric values.
enum LabJSONComparison {
    struct Table {
        let raw: String
        let columns: [String]
        let jsonColumns: [String]
        let from: String
    }
    static func paths(_ text: String) throws -> [String] {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        func visit(_ value: Any, _ path: String) throws -> [String] {
            var result = [path]
            if let object = value as? [String: Any] {
                for key in object.keys.sorted() {
                    let quoted = String(
                        decoding: try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed),
                        as: UTF8.self)
                    result += try visit(object[key]!, path + "." + quoted)
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { result += try visit(child, path + "[\(index)]") }
            }
            return result
        }
        return try visit(value, "$")
    }
    static func scalar(_ type: String, _ hex: String) throws -> String {
        try require(hex != "NULL", "JSON comparison path is missing")
        if type == "OBJECT" || type == "ARRAY" { return "" }  // Paths retain structure and order.
        if type == "DOUBLE" {
            let text = try decode(hex)
            guard let number = Double(text), number.isFinite else {
                throw LabError("invalid JSON double in comparison")
            }
            return String(number.bitPattern, radix: 16)
        }
        return hex  // Exact strings, integers, decimals, temporal and opaque values.
    }
    static func decode(_ hex: String) throws -> String {
        let bytes = Array(hex.utf8)
        try require(bytes.count % 2 == 0, "invalid JSON comparison hex")
        let data = try stride(from: 0, to: bytes.count, by: 2).map { index -> UInt8 in
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else {
                throw LabError("invalid JSON comparison hex")
            }
            return byte
        }
        guard let text = String(bytes: data, encoding: .utf8) else { throw LabError("invalid JSON comparison UTF-8") }
        return text
    }
    /// Share bounded inspection batches across tables. SQL still supplies types
    /// and exact scalar values; table and cell positions remain independent.
    static func rows(
        _ tables: [Table], execute: ([LabSQLBatch.Query]) throws -> [String: String]
    ) throws -> [String] {
        struct Cell {
            let table: Int
            let row: Int
            let column: Int
            var nodes: [[String]] = []
        }
        struct Inspection {
            let cell: Int
            let paths: [String]
            let query: LabSQLBatch.Query
        }
        var rows = try tables.map { table -> [[String]] in
            guard !table.raw.isEmpty, !table.jsonColumns.isEmpty else { return [] }
            let rows = table.raw.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
            try require(rows.allSatisfy { $0.count == table.columns.count }, "JSON comparison row width differs")
            return rows
        }
        var cells: [Cell] = []
        var pending: [Inspection] = []
        var pendingBytes = 0
        let maximumQueries = 32
        let maximumSQLBytes = 256 * 1024
        func flush() throws {
            guard !pending.isEmpty else { return }
            let results = try execute(pending.map(\.query))
            try require(
                Set(results.keys) == Set(pending.map { $0.query.name }), "JSON comparison batch results differ")
            for item in pending {
                let output = results[item.query.name]!
                let fields = output.components(separatedBy: "\t")
                try require(
                    !output.contains("\n") && fields.count == item.paths.count * 2,
                    "JSON comparison path result differs")
                for (i, path) in item.paths.enumerated() {
                    let type = fields[i * 2]
                    cells[item.cell].nodes.append([path, type, try scalar(type, fields[i * 2 + 1])])
                }
            }
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
        }
        for table in tables.indices {
            let input = tables[table]
            for row in rows[table].indices {
                for (index, column) in input.columns.enumerated()
                where input.jsonColumns.contains(where: { LabSQLName.equal($0, column) })
                    && rows[table][row][index] != "<NULL>"
                {
                    let paths = try paths(decode(rows[table][row][index]))
                    let cell = cells.count
                    cells.append(Cell(table: table, row: row, column: index))
                    for start in stride(from: 0, to: paths.count, by: 32) {
                        let part = Array(paths[start..<min(start + 32, paths.count)])
                        let selections = part.flatMap { path -> [String] in
                            let hex = path.utf8.map { String(format: "%02x", $0) }.joined()
                            let value =
                                "JSON_EXTRACT(`" + column.replacingOccurrences(of: "`", with: "``") + "`,CONVERT(0x" + hex
                                + " USING utf8mb4))"
                            return ["JSON_TYPE(" + value + ")", "HEX(JSON_UNQUOTE(" + value + "))"]
                        }
                        let query = LabSQLBatch.Query(
                            name: "json-\(cell)-\(start)",
                            sql: "SET NAMES utf8mb4; SET time_zone='+00:00'; SELECT "
                                + selections.joined(separator: ",") + input.from + " LIMIT 1 OFFSET \(row)",
                            preserveWhitespace: true)
                        let bytes = query.sql.utf8.count
                        if !pending.isEmpty && pendingBytes + bytes > maximumSQLBytes { try flush() }
                        pending.append(Inspection(cell: cell, paths: part, query: query))
                        pendingBytes += bytes
                        if pending.count == maximumQueries || pendingBytes >= maximumSQLBytes { try flush() }
                    }
                }
            }
        }
        try flush()
        for cell in cells {
            rows[cell.table][cell.row][cell.column] =
                try JSONSerialization.data(withJSONObject: cell.nodes).base64EncodedString()
        }
        return tables.indices.map { index in
            let table = tables[index]
            return table.raw.isEmpty || table.jsonColumns.isEmpty
                ? table.raw : rows[index].map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
    }
}
