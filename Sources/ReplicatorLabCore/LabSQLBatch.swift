import Foundation

/// Frame independent fixture queries in one mysql client call. Keep empty
/// results and whitespace so batching cannot weaken a comparison.
struct LabSQLBatch {
    struct Query {
        let name: String
        let sql: String
        var preserveWhitespace = false
    }
    let queries: [Query]
    private let token = "replicator_lab_" + UUID().uuidString

    func marker(_ index: Int) -> String { token + "_" + String(index) }

    var statement: String {
        var parts = ["SET NAMES utf8mb4", "SELECT '\(marker(0))'"]
        for (index, query) in queries.enumerated() {
            parts.append(query.sql)
            parts.append("SELECT '\(marker(index + 1))'")
        }
        return parts.joined(separator: ";\n")
    }

    func decode(_ output: String) throws -> [String: String] {
        try require(Set(queries.map(\.name)).count == queries.count, "duplicate SQL batch query name")
        var lines = output.components(separatedBy: "\n")
        try require(lines.last == "", "incomplete SQL batch output")
        lines.removeLast()
        try require(lines.first == marker(0), "missing SQL batch start")
        var offset = 1
        var result: [String: String] = [:]
        for (index, query) in queries.enumerated() {
            guard let end = lines[offset...].firstIndex(of: marker(index + 1)) else {
                throw LabError("missing SQL batch result: " + query.name)
            }
            let rows = lines[offset..<end]
            try require(!rows.contains(where: { $0.hasPrefix(token) }), "unexpected SQL batch marker")
            let value = rows.joined(separator: "\n")
            result[query.name] = query.preserveWhitespace ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
            offset = end + 1
        }
        try require(offset == lines.count, "extra SQL batch output")
        return result
    }
}
