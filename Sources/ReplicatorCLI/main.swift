import Foundation
import ReplicatorCodec

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--version"] {
        print("mysql-replicator 0.1.0-dev (codec ABI \(Codec.abiVersion), capabilities \(Codec.capabilities))")
        return
    }
    if args.isEmpty || args == ["--help"] {
        print("""
        mysql-replicator — development offline decoder
        Usage: mysql-replicator inspect FILE [--schema HISTORY.json] [--include-raw]
               mysql-replicator --version | --help
        Output: one JSON event per line; diagnostics on stderr, failure exits nonzero.
        Rows require historical signedness/encoding tied to table-map positions.
        Live capture, SQLite relay and target apply are not implemented.
        See PLAN/OFFLINE_INSPECT.md for supported types and schema format.
        """)
        return
    }
    guard args.removeFirst() == "inspect", !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "unsupported command; use --help") }
    let file = URL(fileURLWithPath: args.removeFirst())
    var schemaURL: URL?, includeRaw = false
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--include-raw":
            guard !includeRaw else { throw DecoderError(code: 1, offset: 0, reason: "duplicate --include-raw") }; includeRaw = true
        case "--schema":
            guard schemaURL == nil, !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "--schema requires one history file") }
            schemaURL = URL(fileURLWithPath: args.removeFirst())
        default: throw DecoderError(code: 1, offset: 0, reason: "unknown inspect option")
        }
    }
    var history: SchemaHistory?
    if let schemaURL {
        let file = try FileHandle(forReadingFrom: schemaURL)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 1024 * 1024 else { throw DecoderError(code: 5, offset: 0, reason: "schema file exceeds 1 MiB") }
        history = try JSONDecoder().decode(SchemaHistory.self, from: bytes)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try Inspection.inspect(file: file, history: history, includeRaw: includeRaw) { event in
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(event) + Data([10]))
    }
}
do { try main() }
catch {
    let diagnostic: [String: Any]
    if let failure = error as? DecoderError {
        diagnostic = ["error": "binlog_decode_failed", "code": failure.code, "offset": String(failure.offset), "eventType": failure.eventType.map { Int($0) } as Any? ?? NSNull(), "reason": failure.reason]
    } else { diagnostic = ["error": "inspect_failed", "reason": String(describing: error)] }
    if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    exit(1)
}
