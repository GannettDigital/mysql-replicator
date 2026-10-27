import Foundation

/// Source statements share a client, but retain their session resets and commit
/// boundaries. Result markers identify each statement and its binlog position.
enum LabSQLPhase {
    struct Write {
        let id: String
        let sql: String
        var checkWarnings = false
    }
    struct Result {
        let write: Write
        let start: Boundary
        let end: Boundary
        let gtids: String
        let warnings: String
        var json: [String: Any] {
            [
                "id": write.id, "sql": write.sql, "start": start.json, "end": end.json, "gtids": gtids,
                "warnings": warnings,
            ]
        }
    }
    static func queries(_ writes: [Write], session: String, status: String) throws -> [LabSQLBatch.Query] {
        try require(
            !writes.isEmpty && Set(writes.map(\.id)).count == writes.count, "empty or duplicate SQL phase writes")
        return writes.flatMap { write -> [LabSQLBatch.Query] in
            [
                .init(
                    name: write.id + "/warnings",
                    sql: session + "\nSET @replicator_lab_phase_gtids=@@GLOBAL.gtid_executed;\n" + write.sql
                        + "; SHOW WARNINGS", preserveWhitespace: true),
                .init(
                    name: write.id + "/delta",
                    sql: "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,@replicator_lab_phase_gtids)"),
                .init(name: write.id + "/position", sql: status),
                .init(name: write.id + "/gtids", sql: "SELECT @@GLOBAL.gtid_executed"),
            ]
        }
    }
    static func decode(_ writes: [Write], start: Boundary, values: [String: String]) throws -> [Result] {
        var previous = start
        return try writes.map { write in
            let prefix = write.id + "/"
            guard let warnings = values[prefix + "warnings"], let delta = values[prefix + "delta"],
                let position = values[prefix + "position"], let gtids = values[prefix + "gtids"]
            else { throw LabError("missing phase results: " + write.id) }
            try require(
                !write.checkWarnings || warnings.isEmpty, "\(write.id): unexpected source warnings: \(warnings)")
            let end = try Boundary.read(statusCommand: "unused") { _ in ["position": position, "gtids": gtids] }
            defer { previous = end }
            return Result(write: write, start: previous, end: end, gtids: delta, warnings: warnings)
        }
    }
}

extension SharedCorrectness.Run {
    func sourcePhase(_ id: String, writes: [LabSQLPhase.Write]) throws -> [LabSQLPhase.Result] {
        currentDatabase = "demo"
        sourcePhaseCount += 1
        let previousPhase = f.h.sqlTrace.metadata["phase_id"]
        f.h.sqlTrace.metadata["phase_id"] = id
        defer { f.h.sqlTrace.metadata["phase_id"] = previousPhase }
        let path = f.output.appendingPathComponent("phase-" + id + ".json")
        try writeJSON(["status": "running", "writes": writes.map { ["id": $0.id, "sql": $0.sql] }], to: path)
        f.stage("phase " + id + ": submit \(writes.count) source operations")
        do {
            let start = try f.boundary()
            let queries = try LabSQLPhase.queries(
                writes, session: session, status: f.profile.sourceVersion.binlogStatus)
            let values = try f.h.sqlBatch(f.profile.service(.source), queries)
            let results = try LabSQLPhase.decode(writes, start: start, values: values)
            try wait(until: results.last!.end)
            try writeJSON(["status": "passed", "writes": results.map(\.json)], to: path)
            return results
        } catch {
            try? writeJSON(
                [
                    "status": "failed", "error": String(describing: error),
                    "writes": writes.map { ["id": $0.id, "sql": $0.sql] },
                ], to: path)
            throw LabError("phase \(id): \(error); details: \(path.path)")
        }
    }
}
