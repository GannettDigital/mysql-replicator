import Foundation
import ReplicatorCodec
import ReplicatorCapture
import ReplicatorApply
import ReplicatorConfiguration
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--version"] {
        print("mysql-replicator 0.1.0-dev (codec ABI \(Codec.abiVersion), capabilities \(Codec.capabilities))")
        return
    }
    if args.isEmpty || args == ["--help"] {
        print("""
        mysql-replicator — development binlog inspector and DML applier
        Usage: mysql-replicator inspect FILE [--schema HISTORY.json] [--include-raw]
                   [--transactions --binlog-file SOURCE_FILENAME]
               mysql-replicator inspect --source-config SOURCE.yaml [--transactions] [--include-raw]
               mysql-replicator inspect-relay FILE [--include-raw]
               mysql-replicator run --config APPLY.yaml [--initialize]
               mysql-replicator blackhole --source-config SOURCE.yaml
               mysql-replicator skip GTID_SET --config APPLY.yaml
               mysql-replicator --version | --help
        Configuration: YAML (.yaml or .yml); JSON configuration is not supported.
        Output: one JSON event per line; diagnostics on stderr, failure exits nonzero.
        --transactions emits complete source groups and rejects incomplete EOF.
        Rows require historical signedness/encoding tied to table-map positions.
        Live inspection is read-only and has no durable checkpoint or automatic reconnect.
        run applies qualified DML/DDL; --initialize creates new state from the configured baseline.
        Without --initialize, run resumes clean STOPPED state from SQLite.
        skip excludes the captured failed GTID only when no target write intents exist; leaves STOPPED.
        Source and safe target reconnect are automatic; uncertain writes remain blocked.
        Send SIGUSR1 to run to drain its active batch and exit STOPPED before target maintenance.
        See PLAN/OFFLINE_INSPECT.md for supported types and schema format.
        """)
        return
    }
    if args.first == "inspect-relay" {
        guard args.count == 2 || (args.count == 3 && args[2] == "--include-raw") else {
            throw ApplyError("use inspect-relay FILE [--include-raw]")
        }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        try RelayInspection.inspect(file:URL(fileURLWithPath:args[1]),includeRaw:args.count == 3) {
            try FileHandle.standardOutput.write(contentsOf:encoder.encode($0)+Data([10]))
        }
        return
    }
    if args.first == "blackhole" {
        guard args.count == 3, args[1] == "--source-config" else { throw CaptureError("use blackhole --source-config SOURCE.yaml") }
        let config=try ConfigurationFile.load(CaptureConfiguration.self,from:URL(fileURLWithPath:args[2]))
        let password=try PasswordConfiguration.resolve(password:config.password,environmentVariable:config.passwordEnvironment,endpoint:"source")
        let cancellation=CaptureCancellation()
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN)
        let signals=[SIGINT,SIGTERM].map { number -> DispatchSourceSignal in
            let source=DispatchSource.makeSignalSource(signal:number,queue:.global())
            source.setEventHandler { cancellation.cancel() }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        let result=try BlackholeRun.run(configuration:config,password:password,cancellation:cancellation)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf:encoder.encode(result)+Data([10]))
        return
    }
    if args.first == "skip" {
        guard args.count == 4, args[2] == "--config" else { throw ApplyError("use skip GTID_SET --config APPLY.yaml") }
        let config = try ConfigurationFile.load(ApplyConfiguration.self,from:URL(fileURLWithPath:args[3]))
        let summary = try ApplySkip.run(configuration:config,gtidSet:args[1])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf:encoder.encode(summary) + Data([10]))
        return
    }
    if args.first == "run" {
        guard (args.count == 3 || (args.count == 4 && args[3] == "--initialize")), args[1] == "--config" else { throw ApplyError("use run --config APPLY.yaml [--initialize]") }
        let config = try ConfigurationFile.load(ApplyConfiguration.self,from:URL(fileURLWithPath:args[2]))
        let sourcePassword=try PasswordConfiguration.resolve(password:config.source.password,environmentVariable:config.source.passwordEnvironment,endpoint:"source")
        let targetPassword=try PasswordConfiguration.resolve(password:config.target.password,environmentVariable:config.target.passwordEnvironment,endpoint:"target")
        let cancellation = CaptureCancellation(), drain = CaptureCancellation()
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN); signal(SIGUSR1,SIG_IGN)
        let signals = [SIGINT,SIGTERM,SIGUSR1].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal:number,queue:.global())
            source.setEventHandler { if number == SIGUSR1 { drain.cancel() } else { cancellation.cancel() } }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let summary = try ApplyRun.run(configuration:config,sourcePassword:sourcePassword,targetPassword:targetPassword,initialize:args.count == 4,cancellation:cancellation,drain:drain,
            emitProgress: { try FileHandle.standardOutput.write(contentsOf:encoder.encode($0) + Data([10])) })
        try FileHandle.standardError.write(contentsOf:encoder.encode(summary) + Data([10]))
        return
    }
    guard args.removeFirst() == "inspect", !args.isEmpty else { throw DecoderError(code: 1, offset: 0, reason: "unsupported command; use --help") }
    if args.first == "--source-config" {
        args.removeFirst()
        guard !args.isEmpty else { throw CaptureError("--source-config requires a YAML file") }
        let source = URL(fileURLWithPath: args.removeFirst())
        let config = try ConfigurationFile.load(CaptureConfiguration.self, from: source)
        guard Set(args).count == args.count, args.allSatisfy({ ["--transactions", "--include-raw"].contains($0) }) else {
            throw CaptureError("invalid or duplicate live inspect option")
        }
        let password=try PasswordConfiguration.resolve(password:config.password,environmentVariable:config.passwordEnvironment,endpoint:"source")
        let cancellation = CaptureCancellation()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let signal = DispatchSource.makeSignalSource(signal: number, queue: .global())
            signal.setEventHandler { cancellation.cancel() }; signal.resume(); return signal
        }
        defer { signals.forEach { $0.cancel() } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let transactions = args.contains("--transactions")
        let summary = try LiveInspection.run(configuration: config, password: password, includeRaw: args.contains("--include-raw"), cancellation: cancellation,
            emitEvent: { if !transactions { try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10])) } },
            emitTransaction: { if transactions { try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10])) } })
        try FileHandle.standardError.write(contentsOf: encoder.encode(summary) + Data([10]))
        return
    }
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
func readBounded(_ url: URL) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 1024*1024+1) ?? Data()
    guard data.count <= 1024*1024 else { throw CaptureError("configuration exceeds 1 MiB") }
    return data
}
do { try main() }
catch {
    let diagnostic: [String: Any]
    if CommandLine.arguments.dropFirst().first == "skip" {
        diagnostic = ["error":"skip_failed","reason":String(describing:error)]
    } else if let failure = error as? DecoderError {
        diagnostic = ["error": "binlog_decode_failed", "code": failure.code, "offset": String(failure.offset), "eventType": failure.eventType.map { Int($0) } as Any? ?? NSNull(), "reason": failure.reason]
    } else if let failure = error as? TransactionError {
        func coordinate(_ value: BinlogCoordinate?) -> Any {
            guard let value else { return NSNull() }
            return ["file": value.file, "position": String(value.position)]
        }
        diagnostic = ["error": "binlog_transaction_failed", "code": failure.code.rawValue,
            "coordinate": coordinate(failure.coordinate), "transactionStart": coordinate(failure.transactionStart),
            "lastCompleteBoundary": coordinate(failure.lastCompleteBoundary), "reason": failure.reason]
    } else if let failure = error as? ApplyRunError {
        let progress = (try? JSONEncoder().encode(failure.progress)).flatMap { try? JSONSerialization.jsonObject(with:$0) }
        diagnostic = ["error":"apply_failed","reason":failure.reason,"progress":progress ?? NSNull()]
    } else if let failure = error as? ApplyError {
        diagnostic = ["error":"apply_failed","reason":failure.description]
    } else if let failure = error as? LiveInspectionError {
        let summary = (try? JSONEncoder().encode(failure.summary)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        diagnostic = ["error": "live_capture_failed", "reason": failure.reason, "progress": summary ?? NSNull()]
    } else { diagnostic = ["error": "inspect_failed", "reason": String(describing: error)] }
    if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    exit(1)
}
