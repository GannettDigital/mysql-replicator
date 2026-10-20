import ArgumentParser

/// Parsed requests contain no open files, connections, or replication state.
public enum CLIRequest: Equatable {
    case help(String)
    case version
    case apply(config: String, initialize: Bool, offline: Bool)
    case fetch(config: String)
    case supportBundle(config: String)
    case control(config: String, action: String, timeout: Int)
    case recoveryInspect(config: String)
    case recoveryResolve(config: String, action: String, gtids: String, reason: String)
    case skip(config: String, gtids: String)
    case blackhole(config: String)
    case inspectRelay(file: String, includeRaw: Bool)
    case inspectFile(file: String, schema: String?, includeRaw: Bool, binlogFile: String?)
    case inspectSource(config: String, transactions: Bool, includeRaw: Bool)
}

public struct CLIParseError: Error, CustomStringConvertible {
    public let description: String
}

public enum ReplicatorCommandLine {
    public static func parse(_ arguments: [String]) throws -> CLIRequest {
        do {
            var command = try Root.parseAsRoot(arguments.isEmpty ? ["--help"] : arguments)
            if let request = command as? RequestCommand {
                // Argument Parser permits repeated scalar options. Keep the
                // CLI's existing rejection of duplicates that can hide mistakes.
                let options: Set<String> = [
                    "--config", "--initialize", "--source-config", "--schema",
                    "--include-raw", "--transactions", "--binlog-file", "--gtids", "--reason", "--timeout", "--version",
                ]
                var seen = Set<String>()
                for argument in arguments {
                    if argument == "--" { break }
                    let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                    if options.contains(name), !seen.insert(name).inserted {
                        throw ValidationError("Duplicate option: \(name)")
                    }
                }
                if seen.contains("--version"), arguments != ["--version"] {
                    throw ValidationError("Use --version without a subcommand or other options.")
                }
                return request.request
            }
            if command is Control || command is Recovery {
                throw ValidationError("Select a subcommand. Use --help to list subcommands.")
            }
            // The built-in help command throws CleanExit. It has no runtime work.
            try command.run()
            throw ValidationError("Select a command. Use --help to list commands.")
        } catch {
            if Root.exitCode(for: error) == .success {
                return .help(Root.fullMessage(for: error, columns: 88))
            }
            throw CLIParseError(description: Root.fullMessage(for: error, columns: 88))
        }
    }
}

private protocol RequestCommand: ParsableCommand {
    var request: CLIRequest { get }
}

private struct Root: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "mysql-replicator",
        abstract: "Replicate MySQL binlog changes across supported server versions.",
        discussion: """
            Put connection, profile, and policy settings in a YAML configuration file.
            Commands emit JSON records. Diagnostics go to stderr. Failures exit with status 1.
            Help and version output are plain text and do not connect to MySQL.
            """,
        subcommands: [
            Run.self, Fetch.self, Replay.self, Control.self, SupportBundle.self,
            Inspect.self, InspectRelay.self, Blackhole.self, Skip.self, Recovery.self,
        ])
    @Flag(help: "Show the release version and codec capabilities.") var version = false
    var request: CLIRequest { version ? .version : .help(Self.helpMessage(columns: 88)) }
}

private struct Config: ParsableArguments {
    @Option(
        name: .customLong("config"), help: ArgumentHelp("Read settings from this YAML file.", valueName: "FILE.yaml"))
    var path: String
    mutating func validate() throws {
        guard !path.isEmpty else { throw ValidationError("--config requires a nonempty path.") }
    }
}

private struct ApplyOptions: ParsableArguments {
    @OptionGroup var config: Config
    @Flag(help: "Create new state from the configured baseline. Omit to resume saved state.")
    var initialize = false
}

private struct Run: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Capture from the source and apply changes to the target.",
        discussion: """
            Resume clean STOPPED state unless --initialize is set. Source and safe target
            reconnect are automatic. Uncertain target writes leave the applier BLOCKED.
            Use ctl stop for a graceful drain. SIGTERM and SIGUSR1 also request a drain.
            """)
    @OptionGroup var options: ApplyOptions
    var request: CLIRequest { .apply(config: options.config.path, initialize: options.initialize, offline: false) }
}

private struct Replay: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Apply raw binlog files from a local archive without source access.",
        discussion: """
            Configure the archive directory and baseline in YAML. Replay checks archive
            history and event CRCs before target writes. Use source.stopAfterGTIDs or
            source.stopAfterTransactions in YAML to stop at a transaction boundary.
            """)
    @OptionGroup var options: ApplyOptions
    var request: CLIRequest { .apply(config: options.config.path, initialize: options.initialize, offline: true) }
}

private struct Fetch: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Download a finite source binlog range to a local archive.",
        discussion:
            "Uses source and archive settings from YAML. Does not connect to the target. Use a new archive directory for each fetch."
    )
    @OptionGroup var config: Config
    var request: CLIRequest { .fetch(config: config.path) }
}

private struct SupportBundle: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "support-bundle",
        abstract: "Collect local files to diagnose a replication failure.",
        discussion: """
            Stop the applier before collection. The bundle can contain SQL, row data,
            configuration, and logs. The command does not upload the bundle or connect
            to MySQL. Configure output and size limits under supportBundle in YAML.
            """)
    @OptionGroup var config: Config
    var request: CLIRequest { .supportBundle(config: config.path) }
}

private struct Control: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ctl",
        abstract: "Control a running run or replay process through its local socket.",
        subcommands: [Status.self, Stop.self, Reload.self])
}

private struct ControlOptions: ParsableArguments {
    @OptionGroup var config: Config
    @Option(help: "Wait up to this many seconds (1 to 86400).") var timeout = 60
    mutating func validate() throws {
        guard (1...86400).contains(timeout) else { throw ValidationError("--timeout must be 1 to 86400 seconds.") }
    }
}

private struct Status: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show the running process state and progress.")
    @OptionGroup var options: ControlOptions
    var request: CLIRequest { .control(config: options.config.path, action: "status", timeout: options.timeout) }
}

private struct Stop: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Request a graceful drain and wait for the process to stop.")
    @OptionGroup var options: ControlOptions
    var request: CLIRequest { .control(config: options.config.path, action: "stop", timeout: options.timeout) }
}

private struct Reload: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the transaction and GTID stop limits from YAML.",
        discussion:
            "Only source.stopAfterTransactions and source.stopAfterGTIDs can change. Other settings and a new baseline require a restart."
    )
    @OptionGroup var options: ControlOptions
    var request: CLIRequest { .control(config: options.config.path, action: "reload", timeout: options.timeout) }
}

private struct Recovery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery",
        abstract: "Inspect or resolve blocked replication state.",
        discussion:
            "Stop the applier first. These commands read local state and do not connect to MySQL. Use recovery inspect before recovery resolve.",
        subcommands: [RecoveryInspect.self, RecoveryResolve.self])
}

private struct RecoveryInspect: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show pending transactions and the saved recovery information.")
    @OptionGroup var config: Config
    var request: CLIRequest { .recoveryInspect(config: config.path) }
}

private enum RecoveryAction: String, ExpressibleByArgument {
    case markApplied = "mark-applied"
    case retry, skip
}

private struct RecoveryResolve: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Record a DBA decision for a blocked transaction group.",
        discussion:
            """
            Stop the applier and check the saved records first. Supply the exact pending GTID set and a reason for the decision.

            DDL rejected before a target write intent was saved permits retry only. This applies to all supported profiles. Correct the cause first. DDL with a saved intent cannot use this command.

            For uncertain InnoDB row writes, check and repair the target before you select an action. MyISAM row recovery is not supported.

            Retry keeps the applied checkpoint unchanged. Resume run or replay without --initialize.
            """
    )
    @Argument(help: "Resolution: mark-applied, retry, or skip.") var action: RecoveryAction
    @OptionGroup var config: Config
    @Option(help: ArgumentHelp("GTID set to resolve.", valueName: "GTID_SET")) var gtids: String
    @Option(help: ArgumentHelp("DBA reason for this decision.", valueName: "TEXT")) var reason: String
    var request: CLIRequest {
        .recoveryResolve(config: config.path, action: action.rawValue, gtids: gtids, reason: reason)
    }
}

private struct Skip: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Skip a captured failed GTID that has no target write intents.",
        discussion:
            "The command leaves the applier STOPPED. Use recovery inspect for a group with target write intents.")
    @Argument(help: "Captured failed GTID to exclude.") var gtidSet: String
    @OptionGroup var config: Config
    var request: CLIRequest { .skip(config: config.path, gtids: gtidSet) }
}

private struct Blackhole: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "blackhole",
        abstract: "Measure capture and decoding without a target applier.")
    @Option(name: .long, help: ArgumentHelp("Source-only YAML configuration.", valueName: "SOURCE.yaml"))
    var sourceConfig: String
    var request: CLIRequest { .blackhole(config: sourceConfig) }
}

private struct InspectRelay: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect-relay", abstract: "Read a local relay file and emit JSON records.")
    @Argument(help: "Local relay file.") var file: String
    @Flag(help: "Include raw event bytes as base64.") var includeRaw = false
    var request: CLIRequest { .inspectRelay(file: file, includeRaw: includeRaw) }
}

private struct Inspect: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a raw binlog file or a live source stream.",
        discussion: """
            Supply FILE for local inspection, or --source-config for live inspection.
            Row decoding requires historical column metadata. Use --schema for a local
            schema history. For local transaction output, supply --transactions and
            --binlog-file together. Live inspection is read-only. It has no durable
            checkpoint or automatic reconnect.
            """)
    @Argument(help: "Local raw binlog file. Omit for live inspection.") var file: String?
    @Option(help: ArgumentHelp("Source-only YAML configuration for live inspection.", valueName: "SOURCE.yaml"))
    var sourceConfig: String?
    @Option(help: ArgumentHelp("Historical column metadata for a local file.", valueName: "HISTORY.json")) var schema:
        String?
    @Flag(help: "Include raw event bytes as base64.") var includeRaw = false
    @Flag(help: "Emit complete transaction groups; reject incomplete EOF.") var transactions = false
    @Option(help: ArgumentHelp("Original source filename for local transaction output.", valueName: "SOURCE_FILENAME"))
    var binlogFile: String?
    mutating func validate() throws {
        guard (file != nil) != (sourceConfig != nil) else {
            throw ValidationError("Supply FILE or --source-config, but not both.")
        }
        if sourceConfig != nil {
            guard schema == nil, binlogFile == nil else {
                throw ValidationError("--schema and --binlog-file require a local FILE.")
            }
        } else if transactions != (binlogFile != nil) {
            throw ValidationError("--transactions and --binlog-file must be supplied together for a local FILE.")
        }
    }
    var request: CLIRequest {
        if let sourceConfig {
            return .inspectSource(config: sourceConfig, transactions: transactions, includeRaw: includeRaw)
        }
        return .inspectFile(file: file!, schema: schema, includeRaw: includeRaw, binlogFile: binlogFile)
    }
}
