import Foundation

/// Cold INFORMATION_SCHEMA reads are separate from DML value tests. Keep each
/// distinct schema here, but run only its initial INSERT in one applier session.
enum MetadataDiscoveryCases {
    static let columns = QualificationCase("metadata-columns-indexes", "Read existing column and index definitions")
    static let encodings = QualificationCase("metadata-labels-defaults", "Read encoded labels and stored defaults")
    static let cache = QualificationCase(
        "metadata-cache-ddl", "Reuse metadata and replace it after ALTER, RENAME and DROP")
    static let tests = [columns, encodings, cache]

    // These cases have the same metadata fields as another retained definition.
    // Their complete DML workloads remain with the owners in the migration map.
    static let equivalent: [String: String] = [
        "ignore": "upsert", "replace": "upsert", "values": "upsert",
        "select": "upsert", "load": "upsert", "jsonpartial": "json",
        "typedjson": "json", "enumzero": "exactchoices",
    ]
    static let encoded: Set<String> = [
        "binarychoices", "binarydefaults", "choiceboundaries", "choices", "collations",
        "encodings", "exactchoices", "legacybinaryset", "nativeencodings", "textdefaults",
        "widechoices", "zerowidth",
    ]
    static func representative(_ id: String) -> String { equivalent[id] ?? id }
    static func owner(_ id: String) -> String {
        encoded.contains(representative(id)) ? encodings.id : columns.id
    }
    static func fixtures(_ id: String, profile: LabProfile) -> [DMLCompatibilityCases.Case] {
        DMLCompatibilityCases.cases.filter { equivalent[$0.id] == nil && owner($0.id) == id && $0.applies(to: profile) }
    }
    static func assertions(_ id: String, profile: LabProfile) -> [String] {
        if id == cache.id {
            return ["cold-read", "warm-cache", "alter-refresh", "rename-drop-recreate", "saved-state-resume"]
        }
        return fixtures(id, profile: profile).map { "metadata-" + $0.id } + ["cold-reads-once", "saved-checkpoint"]
    }
    static func replaces(_ id: String) -> [String] {
        DMLCompatibilityCases.cases.filter { owner($0.id) == id }.map { "bootstrap-matrix-" + $0.id }
    }

    /// Live progress omits stage timings. INFO logs retain one record for each
    /// completed outer schema read. Ignore a partial final Docker log record.
    static func schemaReadRecords(_ data: Data) throws -> [[String: Any]] {
        guard let end = data.lastIndex(of: 10) else { return [] }
        return try data[..<end].split(separator: 10).compactMap { line in
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw LabError("invalid application log record")
            }
            guard record["kind"] as? String == "log",
                record["message"] as? String == "Target schema query totals",
                let fields = record["fields"] as? [String: String], fields["database"] == "poc"
            else { return nil }
            guard let queries = fields["queries"].flatMap(Int.init), queries > 0 else {
                throw LabError("schema-read log lacks query counts")
            }
            return record
        }
    }
}
