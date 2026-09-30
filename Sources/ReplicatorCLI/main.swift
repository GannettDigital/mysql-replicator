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
                   [--transactions --binlog-file SOURCE_FILENAME]
               mysql-replicator --version | --help
        Output: one JSON event per line; diagnostics on stderr, failure exits nonzero.
        --transactions emits complete source groups and rejects incomplete EOF.
        Rows require historical signedness/encoding tied to table-map positions.
        Live capture, file relay and SQLite state and target apply are not implemented.
        See PLAN/OFFLINE_INSPECT.md for supported types and schema format.
        """)
        return
    }
    guard args.removeFirst() == "inspect", !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "unsupported command; use --help") }
    let file = URL(fileURLWithPath: args.removeFirst())
    var schemaURL: URL?, includeRaw = false, transactions = false, sourceFile: String?
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--include-raw":
            guard !includeRaw else { throw DecoderError(code: 1, offset: 0, reason: "duplicate --include-raw") }; includeRaw = true
        case "--schema":
            guard schemaURL == nil, !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "--schema requires one history file") }
            schemaURL = URL(fileURLWithPath: args.removeFirst())
        case "--transactions":
            guard !transactions else { throw DecoderError(code: 1, offset: 0, reason: "duplicate --transactions") }
            transactions = true
        case "--binlog-file":
            guard sourceFile == nil, !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "--binlog-file requires one source filename") }
            sourceFile = args.removeFirst()
        default: throw DecoderError(code: 1, offset: 0, reason: "unknown inspect option")
        }
    }
    guard transactions == (sourceFile != nil) else {
        throw DecoderError(code: 1, offset: 0, reason: "--transactions and --binlog-file must be supplied together")
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
    if let sourceFile {
        try Inspection.inspectTransactions(file: file, sourceFile: sourceFile, history: history, includeRaw: includeRaw) { transaction in
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(transaction) + Data([10]))
        }
    } else {
        try Inspection.inspect(file: file, history: history, includeRaw: includeRaw) { event in
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(event) + Data([10]))
        }
    }
}
do { try main() }
catch {
    let diagnostic: [String: Any]
    if let failure = error as? DecoderError {
        diagnostic = ["error": "binlog_decode_failed", "code": failure.code, "offset": String(failure.offset), "eventType": failure.eventType.map { Int($0) } as Any? ?? NSNull(), "reason": failure.reason]
    } else if let failure = error as? TransactionError {
        func coordinate(_ value: BinlogCoordinate?) -> Any {
            guard let value else { return NSNull() }
            return ["file": value.file, "position": String(value.position)]
        }
        diagnostic = ["error": "binlog_transaction_failed", "code": failure.code.rawValue,
            "coordinate": coordinate(failure.coordinate), "transactionStart": coordinate(failure.transactionStart),
            "lastCompleteBoundary": coordinate(failure.lastCompleteBoundary), "reason": failure.reason]
    } else { diagnostic = ["error": "inspect_failed", "reason": String(describing: error)] }
    if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    exit(1)
}
