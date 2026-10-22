import Foundation

/// Harness SQL only. Write before execution so an interrupted call remains visible.
/// This class has the same serial owner as NativeHarness and QualificationReporter.
final class LabSQLTrace {
    struct Request {
        let service: String
        let sql: String
        var kind = "request"
        var queries: [LabSQLBatch.Query] = []
        var resetsGTID = false
        var detached = false

        /// Direct mysql calls bypass the shared SQL helper in some failure tests.
        static func compose(_ arguments: [String], input: Data?) -> Request? {
            guard arguments.first == "exec", let mysql = arguments.firstIndex(of: "mysql"), mysql > 0 else {
                return nil
            }
            let options = arguments.suffix(from: mysql + 1)
            let sql: String
            if let execute = options.firstIndex(of: "-e"), arguments.indices.contains(execute + 1) {
                sql = arguments[execute + 1]
            } else if let input {
                sql = String(decoding: input, as: UTF8.self)
            } else {
                return nil
            }
            return Request(
                service: arguments[mysql - 1], sql: sql, kind: "direct-client",
                detached: arguments[..<mysql].contains("-d"))
        }
    }

    let output: URL
    var context: () -> [String: Any] = { [:] }
    var metadata: [String: Any] = [:]
    var roles = ["source": "source", "native": "native", "target57": "target"]

    init(output: URL) { self.output = output }

    func measure(_ request: Request, _ body: () throws -> CommandResult) throws -> CommandResult {
        let id = UUID().uuidString.lowercased()
        var start = metadata.merging(context()) { _, context in context }
        start.merge([
            "event": "start", "call_id": id, "service": request.service,
            "role": roles[request.service] ?? "unknown", "kind": request.kind,
            "sql": request.sql, "resets_gtid": request.resetsGTID, "detached": request.detached,
            "unix_seconds": Date().timeIntervalSince1970,
            "queries": request.queries.map { ["name": $0.name, "sql": $0.sql] },
        ]) { _, new in new }
        if start["case_id"] == nil { start["scope"] = "outside-case" }
        try append(start)
        let started = ProcessInfo.processInfo.systemUptime
        let result: CommandResult
        do {
            result = try body()
        } catch {
            try append([
                "event": "finish", "call_id": id, "outcome": "error",
                "seconds": ProcessInfo.processInfo.systemUptime - started, "error": String(describing: error),
            ])
            throw error
        }
        var finish: [String: Any] = [
            "event": "finish", "call_id": id,
            "outcome": result.status == 0 ? (request.detached ? "submitted" : "succeeded") : "failed",
            "exit_code": result.status, "seconds": ProcessInfo.processInfo.systemUptime - started,
            "stdout_bytes": result.stdout.count, "stderr_bytes": result.stderr.count,
        ]
        if result.status != 0 {
            finish["error"] = String(decoding: result.stderr.suffix(16_384), as: UTF8.self)
        }
        try append(finish)
        return result
    }

    private func append(_ record: [String: Any]) throws {
        let url = output.appendingPathComponent("sql-trace.jsonl")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var record = record
        record["schema_version"] = 1
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}
