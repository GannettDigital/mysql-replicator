import Foundation

public enum EvidenceVerification {
    /// Recheck recorded physical binlogs without starting Docker or trusting a
    /// previously stored normalized result. Expectations come from workload intent.
    public static func verify(root: URL, directory: URL) throws {
        let runner = ProcessRunner(root: root)
        let decoder = ProcessInfo.processInfo.environment["MYSQLBINLOG"] ?? "mysqlbinlog"
        let version = try runner.run([decoder, "--no-defaults", "--version"]).text
        try require(version.contains("Ver 8.4."), "MySQL 8.4 mysqlbinlog is required")
        guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("result.json"))) as? [String: Any],
              let starts = report["start_boundaries"] as? [String: [String: Any]],
              let ends = report["end_boundaries"] as? [String: [String: Any]],
              let outcome = report["expected_native_outcome"] as? String,
              ["applied", "rejected_1837"].contains(outcome) else {
            throw LabError("missing evidence boundaries/outcome")
        }
        for service in ["source", "native", "target57"] {
            guard let start = starts[service], let end = ends[service],
                  let name = start["file"] as? String, let endName = end["file"] as? String,
                  let position = start["position"] as? NSNumber, let endPosition = end["position"] as? NSNumber else {
                throw LabError("invalid \(service) evidence boundary")
            }
            try require(name == endName && name.range(of: #"^binlog\.[0-9]+$"#, options: .regularExpression) != nil, "unqualified evidence range")
            let file = directory.appendingPathComponent(service).appendingPathComponent(name)
            let decoded = try runner.run([decoder, "--no-defaults", "--verify-binlog-checksum", "--base64-output=DECODE-ROWS", "-vv", file.path])
            let actual = try BinlogReference.parse(String(decoding: decoded.stdout, as: UTF8.self), from: position.uint64Value, before: endPosition.uint64Value)
            let expected = service == "source" ? Fixture.operations : service == "target57" ? [] : outcome == "rejected_1837" ? Array(Fixture.operations.prefix(1)) : Fixture.operations
            try Comparison.operations(actual, expected: expected)
        }
        print("PASS raw evidence: \(directory.path)")
    }
}
