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

// Periphery 3.5.1 does not follow this entry point's top-level invocation.
// periphery:ignore
func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--version"] {
        print("mysql-replicator \(ReleaseVersion.current) (codec ABI \(Codec.abiVersion), capabilities \(Codec.capabilities))")
        return
    }
    if args.isEmpty || args == ["--help"] {
        print("""
        mysql-replicator — cross-version binlog replication
        Usage: mysql-replicator inspect FILE [--schema HISTORY.json] [--include-raw]
                   [--transactions --binlog-file SOURCE_FILENAME]
               mysql-replicator inspect --source-config SOURCE.yaml [--transactions] [--include-raw]
               mysql-replicator inspect-relay FILE [--include-raw]
               mysql-replicator run --config APPLY.yaml [--initialize]
               mysql-replicator fetch --config APPLY.yaml
               mysql-replicator replay --config APPLY.yaml [--initialize]
               mysql-replicator support-bundle --config APPLY.yaml
               mysql-replicator ctl status|stop|reload --config APPLY.yaml [--timeout SECONDS]
               mysql-replicator blackhole --source-config SOURCE.yaml
               mysql-replicator skip GTID_SET --config APPLY.yaml
               mysql-replicator recovery inspect --config APPLY.yaml
               mysql-replicator recovery resolve ACTION --gtids GTID_SET --reason TEXT --config APPLY.yaml
               mysql-replicator --version | --help
        Configuration: YAML (.yaml or .yml); JSON configuration is not supported.
        Output: one JSON event per line; diagnostics on stderr, failure exits nonzero.
        --transactions emits complete source groups and rejects incomplete EOF.
        Rows require historical signedness/encoding tied to table-map positions.
        Live inspection is read-only and has no durable checkpoint or automatic reconnect.
        run applies qualified DML/DDL; --initialize creates new state from the configured baseline.
        fetch archives a finite source binlog range; replay applies local raw binlogs without source access.
        support-bundle collects sensitive local evidence while the applier is stopped; never uploads it.
        Without --initialize, run resumes clean STOPPED state from SQLite.
        skip excludes the captured failed GTID only when no target write intents exist; leaves STOPPED.
        Source and safe target reconnect are automatic; uncertain writes remain blocked.
        ctl stop waits for a graceful drain; SIGTERM/SIGUSR1 request the same drain.
        ctl reload updates only source.stopAfterTransactions and source.stopAfterGTIDs.
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
    if args.first == "recovery" {
        args.removeFirst()
        guard !args.isEmpty else { throw ApplyError("use recovery inspect|resolve; see --help") }
        let command=args.removeFirst()
        var action: Recovery.Action?
        if command == "resolve" {
            guard !args.isEmpty, let value=Recovery.Action(rawValue:args.removeFirst()) else { throw ApplyError("action must be mark-applied, retry, or skip") }
            action=value
        } else if command != "inspect" { throw ApplyError("use recovery inspect or recovery resolve") }
        var options: [String:String] = [:]
        while !args.isEmpty {
            let key=args.removeFirst()
            guard ["--config","--gtids","--reason"].contains(key), options[key] == nil, !args.isEmpty else { throw ApplyError("invalid recovery option") }
            options[key]=args.removeFirst()
        }
        guard let path=options["--config"] else { throw ApplyError("recovery requires --config") }
        let config=try ConfigurationFile.load(ApplyConfiguration.self,from:URL(fileURLWithPath:path))
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let output: Data
        if let action {
            guard let gtids=options["--gtids"], let reason=options["--reason"] else { throw ApplyError("resolution requires --gtids and --reason") }
            output=try encoder.encode(Recovery.resolve(configuration:config,action:action,gtids:gtids,reason:reason))
        } else {
            guard options.count == 1 else { throw ApplyError("inspection accepts only --config") }
            output=try encoder.encode(Recovery.inspect(configuration:config))
        }
        try FileHandle.standardOutput.write(contentsOf:output+Data([10]))
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
    if args.first == "ctl" {
        guard (args.count == 4 || (args.count == 6 && args[4] == "--timeout")),args[2] == "--config" else { throw ApplyError("use ctl status|stop|reload --config APPLY.yaml [--timeout SECONDS]") }
        struct Config:Decodable { let stateDirectory:String }
        let config=try ConfigurationFile.load(Config.self,from:URL(fileURLWithPath:args[3]))
        let timeout=args.count == 6 ? Int(args[5]) : 60
        guard let timeout else { throw ApplyError("invalid control timeout") }
        let response=try ControlClient.request(.init(command:args[1],timeoutSeconds:timeout),stateDirectory:config.stateDirectory)
        try FileHandle.standardOutput.write(contentsOf:response)
        if (try JSONSerialization.jsonObject(with:response) as? [String:Any])?["ok"] as? Bool != true { throw ApplyError("control request was not acknowledged successfully; see response") }
        return
    }
    if args.first == "fetch" || args.first == "support-bundle" {
        guard args.count == 3,args[1] == "--config" else { throw CaptureError("use fetch|support-bundle --config FILE.yaml") }
        let file=URL(fileURLWithPath:args[2]),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data:Data
        if args[0] == "fetch" {
            struct Config:Decodable { let source:CaptureConfiguration;let profile:ReplicationProfile?;let archive:ArchiveConfiguration }
            let c=try ConfigurationFile.load(Config.self,from:file)
            let password=try PasswordConfiguration.resolve(password:c.source.password,environmentVariable:c.source.passwordEnvironment,endpoint:"source")
            let contract:SourceContract = (c.profile ?? .mysql84To57MyISAM).sourceContract
            data=try encoder.encode(ArchiveFetch.run(source:c.source,password:password,archive:c.archive,contract:contract))
        } else {
            let c=try ConfigurationFile.load(SupportBundleConfiguration.self,from:file)
            data=try encoder.encode(SupportBundle.run(configuration:c,redactedConfiguration:ConfigurationFile.diagnosticJSON(from:file),version:ReleaseVersion.current))
        }
        try FileHandle.standardOutput.write(contentsOf:data+Data([10]));return
    }
    if args.first == "run" || args.first == "replay" {
        guard (args.count == 3 || (args.count == 4 && args[3] == "--initialize")), args[1] == "--config" else { throw ApplyError("use run|replay --config APPLY.yaml [--initialize]") }
        let configFile=URL(fileURLWithPath:args[2]).standardizedFileURL
        let configData=try ConfigurationFile.read(from:configFile)
        let config = try ConfigurationFile.decode(ApplyConfiguration.self,from:configData)
        let reloadIdentity=try ConfigurationFile.reloadIdentity(from:configData)
        let offline=args[0] == "replay"
        struct ArchiveOptions:Decodable { let archive:ArchiveConfiguration }
        let archive=try offline ? ArchiveReplay(configuration:ConfigurationFile.decode(ArchiveOptions.self,from:configData).archive,source:config.source,contract:(config.profile ?? .mysql84To57MyISAM).sourceContract,filtered:!(config.replicateWildIgnoreTable ?? []).isEmpty) : nil
        let sourcePassword=try offline ? "" : PasswordConfiguration.resolve(password:config.source.password,environmentVariable:config.source.passwordEnvironment,endpoint:"source")
        let targetPassword=try PasswordConfiguration.resolve(password:config.target.password,environmentVariable:config.target.passwordEnvironment,endpoint:"target")
        let cancellation = CaptureCancellation(), drain = CaptureCancellation()
        let control=RunControl(limits:try StopConditions(transactions:config.source.stopAfterTransactions,gtids:config.source.stopAfterGTIDs),drain:drain) {
            let data=try ConfigurationFile.read(from:configFile)
            guard try ConfigurationFile.reloadIdentity(from:data) == reloadIdentity else { throw ApplyError("reload may change only source.stopAfterTransactions and source.stopAfterGTIDs; other settings require restart, and saved identity/checkpoint restrictions still apply") }
            let candidate=try ConfigurationFile.decode(ApplyConfiguration.self,from:data)
            try candidate.validate(offline:offline)
            return try StopConditions(transactions:candidate.source.stopAfterTransactions,gtids:candidate.source.stopAfterGTIDs)
        }
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN); signal(SIGUSR1,SIG_IGN)
        let signals = [SIGINT,SIGTERM,SIGUSR1].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal:number,queue:.global())
            source.setEventHandler { if number == SIGINT { cancellation.cancel() } else { drain.cancel() } }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let summary = try ApplyRun.run(configuration:config,sourcePassword:sourcePassword,targetPassword:targetPassword,initialize:args.count == 4,cancellation:cancellation,drain:drain,archive:archive,control:control,
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
do { try main() }
catch {
    var diagnostic: [String: Any]
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
        if let code=failure.code { diagnostic["code"]=code.rawValue }
    } else if let failure = error as? ApplyError {
        diagnostic = ["error":"apply_failed","reason":failure.description]
        if let code=failure.code { diagnostic["code"]=code.rawValue }
        if let number=failure.mysqlErrorNumber { diagnostic["mysqlErrorNumber"]=number }
        if let state=failure.sqlState { diagnostic["sqlState"]=state }
    } else if let failure = error as? LiveInspectionError {
        let summary = (try? JSONEncoder().encode(failure.summary)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        diagnostic = ["error": "live_capture_failed", "reason": failure.reason, "progress": summary ?? NSNull()]
    } else { diagnostic = ["error": "inspect_failed", "reason": String(describing: error)] }
    if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    exit(1)
}
