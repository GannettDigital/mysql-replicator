import Foundation

/// Explicitly migrated producers for existing logical DDL obligations. Profile
/// IDs and the 730-obligation denominator stay unchanged during the migration.
enum SharedCatalogSupport {
    static var caseIDs: Set<String> {
        Set(
            DatabaseCreationCases.cases.map { $0.test.id } + ModifyIndexCases.sharedTests.map { $0.id }
                + DDLCoverageCases.changes.map { $0.test.id } + [DDLCoverageCases.group.id, "matrix-encodings"])
    }
    static func export(
        root: URL, output: URL, profile: String, inputs: [String: String], contracts: [String: String],
        runtime: [String: Any], results: [[String: Any]], result: [String: Any]
    ) throws {
        let directory = output.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selected = results.filter { ($0["id"] as? String).map(caseIDs.contains) ?? false }
        for test in selected {
            for assertion in test["assertions"] as? [[String: Any]] ?? [] {
                if let path = assertion["evidence"] as? String {
                    try DDLCoverage.safePath(path)
                    let destination = directory.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: output.appendingPathComponent(path), to: destination)
                }
            }
        }
        try writeJSON(selected, to: directory.appendingPathComponent("cases.json"))
        try writeJSON(result, to: directory.appendingPathComponent("result.json"))
        try DDLCoverageEvidence.save(
            root: root, output: directory, profile: profile, inputs: inputs, contracts: contracts, runtime: runtime,
            results: selected, producer: "shared-correctness")
    }
}

extension SharedCorrectness.Run {
    func assertion(_ id: String, caseID: String, _ body: () throws -> Any) throws {
        try reporter.assertion(id, evidence: "assertions/" + caseID + "/" + id + ".json", body)
    }
    func snapshot(_ label: String) throws -> URL {
        let directory = f.output.appendingPathComponent("snapshot-" + label)
        _ = try f.docker(["cp", f.helper + ":/evidence/state", directory.path])
        return directory.appendingPathComponent("state.sqlite")
    }
    /// SQL literals for this case's DDL GTIDs. Let MySQL interpret GTID sets,
    /// including intervals and tags, instead of duplicating that parser here.
    func ddlGTIDs(_ saved: URL, from start: Boundary, to end: Boundary) throws -> String {
        let candidates = try state(saved, "SELECT gtid FROM ddl_intents ORDER BY rowid").split(separator: "\n").map(
            String.init)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let delta = try f.sql(.source, "SELECT GTID_SUBTRACT(\(quoted(end.gtids)),\(quoted(start.gtids)))")
        try require(!candidates.isEmpty, "case has no saved DDL GTIDs")
        let checks = candidates.map { "GTID_SUBSET(\(quoted($0)),\(quoted(delta)))" }.joined(separator: ",")
        let flags = try f.sql(.source, "SELECT " + checks).split(separator: "\t")
        try require(flags.count == candidates.count, "DDL GTID membership result differs")
        let selected = zip(candidates, flags).filter { $0.1 == "1" }.map { quoted($0.0) }
        try require(!selected.isEmpty, "case has no DDL GTIDs in its source interval")
        return selected.joined(separator: ",")
    }
    func state(_ file: URL, _ sql: String) throws -> String {
        try f.runner.run(["sqlite3", file.path, sql]).text
    }
    func copyBinlog(_ role: LabProfile.Role, file: String, label: String) throws -> URL {
        let path = f.output.appendingPathComponent(role.rawValue + "-" + label + "-" + file)
        try f.h.compose(["exec", "-T", f.profile.service(role), "cat", "/var/lib/mysql/" + file]).stdout.write(to: path)
        return path
    }
}
