import Foundation
import ReplicatorApply
import ReplicatorCapture
import ReplicatorCodec
import ReplicatorCommandLine
import ReplicatorConfiguration

#if canImport(Musl)
    import Musl
#elseif canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

// Argument parsing is separate from file, socket, and database operations.
func execute(_ request: CLIRequest, overrides: ConfigurationOverrides) throws {
    switch request {
    case .help(let text):
        print(text + "\n" + ConfigurationOptions.help)
    case .version:
        print(
            "mysql-replicator \(ReleaseVersion.current) (codec ABI \(Codec.abiVersion), capabilities \(Codec.capabilities))"
        )
    case .inspectRelay(let path, let includeRaw):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try RelayInspection.inspect(file: URL(fileURLWithPath: path), includeRaw: includeRaw) {
            try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10]))
        }
        return
    case .blackhole(let path):
        let config = try overrides.load(CaptureConfiguration.self, from: URL(fileURLWithPath: path))
        let password = try PasswordConfiguration.resolve(
            password: config.password, environmentVariable: config.passwordEnvironment, endpoint: "source")
        let cancellation = CaptureCancellation()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let result = try BlackholeRun.run(configuration: config, password: password, cancellation: cancellation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data([10]))
        return
    case .recoveryInspect(let path):
        try recover(path: path, overrides: overrides)
    case .recoveryResolve(let path, let action, let gtids, let reason):
        try recover(path: path, overrides: overrides, action: action, gtids: gtids, reason: reason)
    case .skip(let path, let gtids):
        let config = try overrides.load(ApplyConfiguration.self, from: URL(fileURLWithPath: path))
        let summary = try ApplySkip.run(configuration: config, gtidSet: gtids)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(summary) + Data([10]))
        return
    case .control(let path, let action, let timeout):
        struct Config: Decodable { let stateDirectory: String }
        let config = try overrides.load(Config.self, from: URL(fileURLWithPath: path))
        let response = try ControlClient.request(
            .init(command: action, timeoutSeconds: timeout), stateDirectory: config.stateDirectory)
        let object = try JSONSerialization.jsonObject(with: response)
        let output = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
        if (object as? [String: Any])?["ok"] as? Bool != true {
            throw ApplyError("control request was not acknowledged successfully; see response")
        }
        return
    case .fetch(let path), .supportBundle(let path):
        let file = URL(fileURLWithPath: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        if case .fetch = request {
            struct Config: Decodable {
                let source: CaptureConfiguration
                let profile: ReplicationProfile?
                let archive: ArchiveConfiguration
            }
            let c = try overrides.load(Config.self, from: file)
            let password = try PasswordConfiguration.resolve(
                password: c.source.password, environmentVariable: c.source.passwordEnvironment, endpoint: "source")
            let contract: SourceContract = (c.profile ?? .mysql84To57MyISAM).sourceContract
            data = try encoder.encode(
                ArchiveFetch.run(source: c.source, password: password, archive: c.archive, contract: contract))
        } else {
            let c = try overrides.load(SupportBundleConfiguration.self, from: file)
            data = try encoder.encode(
                SupportBundle.run(
                    configuration: c,
                    redactedConfiguration: ConfigurationFile.diagnosticJSON(from: overrides.read(from: file)),
                    version: ReleaseVersion.current))
        }
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        return
    case .apply(let path, let initialize, let offline):
        let configFile = URL(fileURLWithPath: path).standardizedFileURL
        let configData = try overrides.read(from: configFile)
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: configData)
        let reloadIdentity = try ConfigurationFile.reloadIdentity(from: configData)
        struct ArchiveOptions: Decodable { let archive: ArchiveConfiguration }
        let archive =
            try offline
            ? ArchiveReplay(
                configuration: ConfigurationFile.decode(ArchiveOptions.self, from: configData).archive,
                source: config.source, contract: (config.profile ?? .mysql84To57MyISAM).sourceContract,
                filtered: !(config.replicateWildIgnoreTable ?? []).isEmpty
                    || !(config.replicateWildDoTable ?? []).isEmpty,
                progress: { progress in
                    if let data = try? JSONEncoder().encode(progress) {
                        try? FileHandle.standardError.write(contentsOf: data + Data([10]))
                    }
                }) : nil
        let sourcePassword =
            try offline
            ? ""
            : PasswordConfiguration.resolve(
                password: config.source.password, environmentVariable: config.source.passwordEnvironment,
                endpoint: "source")
        let targetPassword = try PasswordConfiguration.resolve(
            password: config.target.password, environmentVariable: config.target.passwordEnvironment, endpoint: "target"
        )
        let cancellation = CaptureCancellation()
        let drain = CaptureCancellation()
        let control = RunControl(
            limits: try StopConditions(
                transactions: config.source.stopAfterTransactions, gtids: config.source.stopAfterGTIDs), drain: drain
        ) {
            let data = try overrides.read(from: configFile)
            guard try ConfigurationFile.reloadIdentity(from: data) == reloadIdentity else {
                throw ApplyError(
                    "reload may change only source.stopAfterTransactions and source.stopAfterGTIDs; other settings require restart, and saved identity/checkpoint restrictions still apply"
                )
            }
            let candidate = try ConfigurationFile.decode(ApplyConfiguration.self, from: data)
            try candidate.validate(offline: offline)
            return try StopConditions(
                transactions: candidate.source.stopAfterTransactions, gtids: candidate.source.stopAfterGTIDs)
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        let signals = [SIGINT, SIGTERM, SIGUSR1].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { if number == SIGINT { cancellation.cancel() } else { drain.cancel() } }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let summary = try ApplyRun.run(
                configuration: config, sourcePassword: sourcePassword, targetPassword: targetPassword,
                initialize: initialize, cancellation: cancellation, drain: drain, archive: archive, control: control,
                emitProgress: { try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10])) })
            try FileHandle.standardError.write(contentsOf: encoder.encode(summary) + Data([10]))
        } catch var failure as ApplyRunError {
            if config.supportBundle?.onBlocked == true, failure.progress.lifecycle == "BLOCKED" {
                // ApplyRun has released the state writer before collection.
                // Config parsing already succeeded; use its original bytes.
                do {
                    let request = try ConfigurationFile.decode(SupportBundleConfiguration.self, from: configData)
                    failure.supportBundle = SupportBundle.onBlocked(
                        failure, configuration: request,
                        redactedConfiguration: try ConfigurationFile.diagnosticJSON(from: configData),
                        version: ReleaseVersion.current)
                } catch {
                    failure.supportBundle = .init(status: "failed", bundle: nil, reason: String(describing: error))
                }
            }
            throw failure
        }
        return
    case .inspectSource(let path, let transactions, let includeRaw):
        let source = URL(fileURLWithPath: path)
        let config = try overrides.load(CaptureConfiguration.self, from: source)
        let password = try PasswordConfiguration.resolve(
            password: config.password, environmentVariable: config.passwordEnvironment, endpoint: "source")
        let cancellation = CaptureCancellation()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let signal = DispatchSource.makeSignalSource(signal: number, queue: .global())
            signal.setEventHandler { cancellation.cancel() }
            signal.resume()
            return signal
        }
        defer { signals.forEach { $0.cancel() } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let summary = try LiveInspection.run(
            configuration: config, password: password, includeRaw: includeRaw, cancellation: cancellation,
            emitEvent: {
                if !transactions { try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10])) }
            },
            emitTransaction: {
                if transactions { try FileHandle.standardOutput.write(contentsOf: encoder.encode($0) + Data([10])) }
            })
        try FileHandle.standardError.write(contentsOf: encoder.encode(summary) + Data([10]))
        return
    case .inspectFile(let path, let schemaPath, let includeRaw, let sourceFile):
        let file = URL(fileURLWithPath: path)
        let schemaURL = schemaPath.map { URL(fileURLWithPath: $0) }
        var history: SchemaHistory?
        if let schemaURL {
            let file = try FileHandle(forReadingFrom: schemaURL)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard bytes.count <= 1024 * 1024 else {
                throw DecoderError(code: 5, offset: 0, reason: "schema file exceeds 1 MiB")
            }
            history = try JSONDecoder().decode(SchemaHistory.self, from: bytes)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let sourceFile {
            try Inspection.inspectTransactions(
                file: file, sourceFile: sourceFile, history: history, includeRaw: includeRaw
            ) { transaction in
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(transaction) + Data([10]))
            }
        } else {
            try Inspection.inspect(file: file, history: history, includeRaw: includeRaw) { event in
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(event) + Data([10]))
            }
        }
    }
}

func recover(
    path: String, overrides: ConfigurationOverrides, action: String? = nil, gtids: String? = nil, reason: String? = nil
) throws {
    let config = try overrides.load(ApplyConfiguration.self, from: URL(fileURLWithPath: path))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output: Data
    if let action {
        guard let action = Recovery.Action(rawValue: action), let gtids, let reason else {
            throw ApplyError("invalid recovery resolution")
        }
        output = try encoder.encode(
            Recovery.resolve(configuration: config, action: action, gtids: gtids, reason: reason))
    } else {
        output = try encoder.encode(Recovery.inspect(configuration: config))
    }
    try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    return
}

// Keep the existing JSON error categories and exit status for argument failures.
func argumentFailure(_ error: CLIParseError, arguments: [String]) -> Error {
    switch arguments.first {
    case "run", "replay", "ctl", "recovery", "skip":
        return ApplyError(error.description)
    case "fetch", "support-bundle", "blackhole":
        return CaptureError(error.description)
    case "inspect" where arguments.contains(where: { $0 == "--source-config" || $0.hasPrefix("--source-config=") }):
        return CaptureError(error.description)
    case "inspect-relay":
        return ApplyError(error.description)
    default:
        return DecoderError(code: 1, offset: 0, reason: error.description)
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let overrides = try ConfigurationOverrides(arguments: arguments)
    let request: CLIRequest
    do { request = try ReplicatorCommandLine.parse(overrides.arguments) } catch let error as CLIParseError {
        throw argumentFailure(error, arguments: arguments)
    }
    try execute(request, overrides: overrides)
} catch {
    var diagnostic: [String: Any]
    if CommandLine.arguments.dropFirst().first == "skip" {
        diagnostic = ["error": "skip_failed", "reason": String(describing: error)]
    } else if let failure = error as? DecoderError {
        diagnostic = [
            "error": "binlog_decode_failed", "code": failure.code, "offset": String(failure.offset),
            "eventType": failure.eventType.map { Int($0) } as Any? ?? NSNull(), "reason": failure.reason,
        ]
    } else if let failure = error as? TransactionError {
        func coordinate(_ value: BinlogCoordinate?) -> Any {
            guard let value else { return NSNull() }
            return ["file": value.file, "position": String(value.position)]
        }
        diagnostic = [
            "error": "binlog_transaction_failed", "code": failure.code.rawValue,
            "coordinate": coordinate(failure.coordinate), "transactionStart": coordinate(failure.transactionStart),
            "lastCompleteBoundary": coordinate(failure.lastCompleteBoundary), "reason": failure.reason,
        ]
    } else if let failure = error as? ApplyRunError {
        let progress = (try? JSONEncoder().encode(failure.progress)).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        }
        diagnostic = ["error": "apply_failed", "reason": failure.reason, "progress": progress ?? NSNull()]
        if let code = failure.code { diagnostic["code"] = code.rawValue }
        if let bundle = failure.supportBundle, let bytes = try? JSONEncoder().encode(bundle) {
            diagnostic["supportBundle"] = try? JSONSerialization.jsonObject(with: bytes)
        }
    } else if let failure = error as? ApplyError {
        diagnostic = ["error": "apply_failed", "reason": failure.description]
        if let code = failure.code { diagnostic["code"] = code.rawValue }
        if let number = failure.mysqlErrorNumber { diagnostic["mysqlErrorNumber"] = number }
        if let state = failure.sqlState { diagnostic["sqlState"] = state }
    } else if let failure = error as? LiveInspectionError {
        let summary = (try? JSONEncoder().encode(failure.summary)).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        }
        diagnostic = ["error": "live_capture_failed", "reason": failure.reason, "progress": summary ?? NSNull()]
    } else {
        diagnostic = ["error": "inspect_failed", "reason": String(describing: error)]
    }
    if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    exit(1)
}
