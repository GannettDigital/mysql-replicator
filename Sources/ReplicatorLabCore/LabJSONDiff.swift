import Foundation

/// Inspect mysqlbinlog output for the known two-column JSON fixture. This is
/// independent of the production decoder, not a general binlog text parser.
enum LabJSONDiff {
    enum Operation: String {
        case replace = "JSON_REPLACE"
        case remove = "JSON_REMOVE"
    }
    struct Phase {
        let phase: Int
        let operation: Operation
    }
    struct Check {
        let writeID: String
        let table: String
        let operation: Operation

        func window(_ results: [LabSQLPhase.Result]) throws -> LabSQLPhase.Result {
            let matches = results.filter { $0.write.id == writeID }
            try require(matches.count == 1, "missing or duplicate JSON diff write: " + writeID)
            let result = matches[0]
            try require(
                result.start.file == result.end.file && result.start.position < result.end.position,
                "JSON diff write rotated or has an empty/reversed source range: " + writeID)
            try require(
                try DMLCompatibilityCases.transactionCount(result.gtids) == 1,
                "JSON diff range must contain one source GTID: " + writeID)
            return result
        }

        func verify(_ text: String, result: LabSQLPhase.Result) throws -> [String: Any] {
            _ = try window([result])
            var position: UInt64 = 0
            var partial = false
            var inSet = false
            var events: [(UInt64, UInt64)] = []
            var rows = 0
            var operations = 0
            var gtids: [String] = []
            let quoted = table.split(separator: ".").map { "`" + $0 + "`" }.joined(separator: ".")
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("# at ") {
                    guard let offset = UInt64(line.dropFirst(5)) else {
                        throw LabError("invalid JSON diff event offset")
                    }
                    position = offset
                    partial = false
                    inSet = false
                    continue
                }
                guard position >= result.start.position && position < result.end.position else { continue }
                if line.hasPrefix("SET @@SESSION.GTID_NEXT=") && !line.contains("'AUTOMATIC'") {
                    gtids.append(line)
                }
                if line.contains("Update_rows_partial:") {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    guard let marker = fields.firstIndex(of: "end_log_pos"), marker + 1 < fields.count,
                        let end = UInt64(fields[marker + 1]), end > position && end <= result.end.position
                    else { throw LabError("JSON diff event exceeds its source range") }
                    events.append((position, end))
                    partial = true
                }
                if line.hasPrefix("### UPDATE ") || line.hasPrefix("### INSERT INTO ")
                    || line.hasPrefix("### DELETE FROM ")
                {
                    try require(
                        partial && line == "### UPDATE " + quoted, "unexpected row event/table in JSON diff range")
                    rows += 1
                    inSet = false
                } else if line == "### SET" {
                    inSet = true
                } else if inSet && line.hasPrefix("###   @2=" + operation.rawValue + "(") {
                    try require(partial && rows == 1, "JSON diff operation is outside its UPDATE")
                    operations += 1
                }
            }
            try require(
                events.count == 1 && rows == 1 && operations == 1 && gtids.count == 1
                    && gtids[0].contains("GTID_NEXT= '" + result.gtids + "'"),
                "source range did not contain the expected partial JSON UPDATE: " + writeID)
            return [
                "writeID": writeID, "table": table, "operation": operation.rawValue,
                "source": ["start": result.start.json, "end": result.end.json, "gtids": result.gtids],
                "eventType": "Update_rows_partial", "eventPosition": events[0].0, "eventEndPosition": events[0].1,
            ]
        }
    }
}

extension SharedCorrectness.Run {
    func verifyJSONDiffs(_ checks: [LabJSONDiff.Check], results: [LabSQLPhase.Result], caseID: String) throws {
        guard !checks.isEmpty else { return }
        if referenceDecoderVersion.isEmpty {
            referenceDecoderVersion = try f.runner.run([f.h.decoder, "--no-defaults", "--version"]).text
        }
        try require(
            referenceDecoderVersion.contains("Ver 8.4."),
            "Partial JSON checks require MySQL 8.4 mysqlbinlog; set MYSQLBINLOG")
        let container = try f.h.compose(["ps", "-q", f.profile.service(.source)]).text
        var files: [String: URL] = [:]
        for check in checks {
            try assertion("source-json-diff-" + check.writeID, caseID: caseID) {
                let result = try check.window(results)
                let raw: URL
                if let cached = files[result.start.file] {
                    raw = cached
                } else {
                    raw = f.output.appendingPathComponent(caseID + "-source-" + result.start.file)
                    _ = try f.docker(["cp", container + ":/var/lib/mysql/" + result.start.file, raw.path])
                    files[result.start.file] = raw
                }
                let output = try f.runner.run([
                    f.h.decoder, "--no-defaults", "--verify-binlog-checksum", "--base64-output=DECODE-ROWS", "-vv",
                    "--start-position=\(result.start.position)", "--stop-position=\(result.end.position)", raw.path,
                ]).stdout
                let decoded = f.output.appendingPathComponent(caseID + "-" + check.writeID + "-source-diff.txt")
                try output.write(to: decoded)
                var evidence = try check.verify(String(decoding: output, as: UTF8.self), result: result)
                evidence["rawBinlog"] = raw.lastPathComponent
                evidence["decodedBinlog"] = decoded.lastPathComponent
                evidence["mysqlbinlogVersion"] = referenceDecoderVersion
                return evidence
            }
        }
    }
}
