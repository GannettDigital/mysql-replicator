import ArgumentParser
import ReplicatorLabCore

/// Parsing does not open files or start containers. Runtime work stays in LabCore.
public enum LabCLIRequest: Equatable {
    case help(String)
    case run(command: String, arguments: [String])
}
public struct LabCLIParseError: Error, CustomStringConvertible {
    public let description: String
}
public enum ReplicatorLabCommandLine {
    public static func parse(_ arguments: [String]) throws -> LabCLIRequest {
        do {
            var command = try Root.parseAsRoot(arguments.isEmpty ? ["--help"] : arguments)
            if let command = command as? LabRequestCommand {
                let request = command.request
                if case .run(let name, let args) = request {
                    if name == "test" { try LabTests.validate(arguments: args) }
                    if name == "benchmark" { try LabBenchmark.validate(arguments: args) }
                }
                return request
            }
            // Argument Parser implements `help COMMAND` through CleanExit.
            try command.run()
            throw ValidationError("Select a subcommand. Use --help to list commands.")
        } catch {
            if Root.exitCode(for: error) == .success {
                return .help(Root.fullMessage(for: error, columns: 88))
            }
            throw LabCLIParseError(description: Root.fullMessage(for: error, columns: 88))
        }
    }
}
private protocol LabRequestCommand: ParsableCommand {
    var request: LabCLIRequest { get }
}
private struct Root: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replicator-lab",
        abstract: "Test MySQL replication, run demos, and measure performance.",
        discussion: "Run commands from the repository root. Help works from any directory. Use test --list for a JSON test inventory. Tests retain logs and results under artifacts/.",
        subcommands: [Test.self, Demo.self, Benchmark.self, BuildInputs.self,
            NativeSuite.self, NativeSmoke.self, UbuntuSmoke.self, LiveSuite.self,
            NativeDDLSuite.self, Catalog.self, UpstreamTests.self, PackageDeb.self,
            ReverseCorrectness.self, ReverseSuite.self, VerifyEvidence.self])
}
private func option(_ name: String, _ value: (any CustomStringConvertible)?) -> [String] {
    value.map { ["--" + name, $0.description] } ?? []
}
private func flag(_ name: String, _ enabled: Bool) -> [String] { enabled ? ["--" + name] : [] }
private let profileHelp = "Replication profile: " + LabProfile.allCases.map(\.rawValue).joined(separator: ", ") + "."
private struct ProfileOption: ParsableArguments {
    @Option(help: ArgumentHelp(profileHelp)) var profile: String
    mutating func validate() throws {
        guard LabProfile(rawValue: profile) != nil else { throw ValidationError("Unknown profile: " + profile) }
    }
    var arguments: [String] { option("profile", profile) }
}
private enum Toggle: String, ExpressibleByArgument { case on, off }
private enum BenchmarkMode: String, ExpressibleByArgument { case backlog, streaming, capture }
private enum ReportFormat: String, ExpressibleByArgument { case markdown, json }
private enum Resolution: String, ExpressibleByArgument { case retry, skip; case markApplied = "mark-applied" }

private struct Test: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run selected tests or print their inventory.")
    @Option(help: "One profile or all. Default: all.") var profile: String?
    @Option(help: "correctness, lifecycle, recovery, demo, native, or all. Default: correctness.") var suite: String?
    @Option(help: "full or smoke. Prefer --case to select named cases. Default: full.") var tier: String?
    @Option(help: "Select one test family. Use --list to inspect the inventory.") var family: String?
    @Option(name: .customLong("case"), help: "Select a case ID. Repeat this option to select more cases.") var cases: [String] = []
    @Option(help: "default, position-minimal, gtid-full, or all. Default: default.") var variant: String?
    @Flag(name: .customLong("list"), help: "Print the JSON inventory without running tests.") var list = false
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing lab image.") var skipBuild = false
    @Flag(name: .customLong("coverage"), help: "Collect runtime code coverage.") var coverage = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("profile", profile)
        arguments += option("suite", suite)
        arguments += option("tier", tier)
        arguments += option("family", family)
        for value in cases { arguments += option("case", value) }
        arguments += option("variant", variant)
        arguments += flag("list", list)
        arguments += flag("skip-build", skipBuild)
        arguments += flag("coverage", coverage)
        return .run(command: "test", arguments: arguments)
    }
}

private struct Demo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo",
        abstract: "Manage a retained demo for one replication profile.",
        subcommands: [DemoUp.self, DemoStart.self, DemoStop.self, DemoStatus.self,
            DemoCompare.self, DemoSQL.self, DemoFail.self, DemoSkip.self,
            DemoInspect.self, DemoResolve.self, DemoDown.self, DemoLegacyDown.self])
}

private struct DemoStart: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start or resume the applier.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["start"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoStop: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Drain and stop the applier.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["stop"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoStatus: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show container and replication status.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["status"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoFail: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "fail", abstract: "Cause the MyISAM engine refusal used by the demo.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["fail"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoInspect: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect pending InnoDB recovery records.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["inspect"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoDown: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Remove the demo containers and volumes.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["down"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoLegacyDown: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "legacy-down", abstract: "Remove a retained legacy demo.")
    @OptionGroup var profile: ProfileOption
    var request: LabCLIRequest {
        var arguments: [String] = ["legacy-down"]
        arguments += profile.arguments
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoUp: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Create or reuse a demo.")
    @OptionGroup var profile: ProfileOption
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing image.") var skipBuild = false
    @Flag(name: .customLong("coverage"), help: "Collect runtime code coverage.") var coverage = false
    var request: LabCLIRequest {
        var arguments: [String] = ["up"]
        arguments += profile.arguments
        arguments += flag("skip-build", skipBuild)
        arguments += flag("coverage", coverage)
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoSQL: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "sql", abstract: "Send a SQL file to the source.")
    @OptionGroup var profile: ProfileOption
    @Argument(help: "Path to the SQL file.") var file: String
    var request: LabCLIRequest {
        var arguments: [String] = ["sql"]
        arguments += profile.arguments
        arguments.append(file)
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoSkip: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "skip", abstract: "Skip one GTID in a MyISAM demo.")
    @OptionGroup var profile: ProfileOption
    @Argument(help: "GTID to skip.") var gtid: String
    var request: LabCLIRequest {
        var arguments: [String] = ["skip"]
        arguments += profile.arguments
        arguments.append(gtid)
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoCompare: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "compare", abstract: "Compare source, native replica, and target.")
    @OptionGroup var profile: ProfileOption
    @Flag(name: .customLong("expect-blocked"), help: "Check the expected MyISAM blocked state.") var expectBlocked = false
    var request: LabCLIRequest {
        var arguments: [String] = ["compare"]
        arguments += profile.arguments
        arguments += flag("expect-blocked", expectBlocked)
        return .run(command: "demo", arguments: arguments)
    }
}

private struct DemoResolve: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "resolve", abstract: "Record an InnoDB recovery decision.")
    @OptionGroup var profile: ProfileOption
    @Argument(help: "retry, skip, or mark-applied.") var action: Resolution
    @Option(help: "Exact pending GTID set.") var gtids: String
    @Option(help: "Operator reason for this decision.") var reason: String
    var request: LabCLIRequest {
        .run(command: "demo", arguments: ["resolve"] + profile.arguments + [action.rawValue, "--gtids", gtids, "--reason", reason])
    }
}

private struct Benchmark: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "benchmark", abstract: "Compare native and external replication time.")
    @OptionGroup var profile: ProfileOption
    @Option(help: "backlog on all profiles; streaming and capture on the forward profile.") var mode: BenchmarkMode = .backlog
    @Option(help: "insert or multi-table-transaction for backlog; insert or mixed for streaming/capture.") var workload: String?
    @Option(name: .customLong("target-transport"), help: "Streaming: tcp-tls, unix-tls, or unix.") var targetTransport: String?
    @Option(name: .customLong("table-distribution"), help: "Streaming: uniform or hot80 (requires at least two tables).") var tableDistribution: String?
    @Option(name: .customLong("events"), help: "Transaction count. Backlog: 1...100000; streaming/capture: 1...1000000.") var events: Int?
    @Option(name: .customLong("batch-transactions"), help: "Backlog/streaming: 1...256 transactions per batch.") var batchTransactions: Int?
    @Option(name: .customLong("prepared-batches"), help: "Backlog: 1...16 prepared batches.") var preparedBatches: Int?
    @Option(name: .customLong("tables"), help: "Streaming: 1...32 tables.") var tables: Int?
    @Option(name: .customLong("table-run"), help: "Streaming: 1...10000 events before a table switch.") var tableRun: Int?
    @Option(name: .customLong("threads"), help: "Streaming/capture: 1...32 load threads.") var threads: Int?
    @Option(name: .customLong("rate"), help: "Streaming/capture: 0...100000 events/s; 0 is unlimited.") var rate: Int?
    @Option(name: .customLong("insert-rows"), help: "Streaming: 1...128 rows per INSERT.") var insertRows: Int?
    @Option(name: .customLong("rows-per-event"), help: "Streaming/capture: 1...100 rows per event.") var rowsPerEvent: Int?
    @Option(name: .customLong("payload-bytes"), help: "Streaming/capture: 0...1024 payload bytes per row.") var payloadBytes: Int?
    @Option(name: .customLong("sample-seconds"), help: "Streaming: 1...30 seconds between samples.") var sampleSeconds: Int?
    @Option(name: .customLong("timeout"), help: "Streaming/capture: 10...3600 seconds per phase.") var timeout: Int?
    @Option(name: .customLong("decoder-profile"), help: "Collect decoder timings (on/off).") var decoderProfile: Toggle?
    @Option(name: .customLong("applier-profile"), help: "Backlog/streaming: collect applier timings (on/off).") var applierProfile: Toggle?
    @Option(name: .customLong("server-profile"), help: "Backlog: collect MySQL server timings (on/off).") var serverProfile: Toggle?
    @Option(name: .customLong("overlap-preparation"), help: "Streaming: overlap preparation and execution (on/off).") var overlapPreparation: Toggle?
    @Option(name: .customLong("flush-on-table-change"), help: "Streaming: flush a batch when the table changes (on/off).") var flushOnTableChange: Toggle?
    @Option(name: .customLong("explicit-table-locks"), help: "Streaming: use explicit target table locks (on/off).") var explicitTableLocks: Toggle?
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing images.") var skipBuild = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += profile.arguments
        arguments += option("mode", mode.rawValue)
        arguments += option("workload", workload)
        arguments += option("target-transport", targetTransport)
        arguments += option("table-distribution", tableDistribution)
        arguments += option("events", events)
        arguments += option("batch-transactions", batchTransactions)
        arguments += option("prepared-batches", preparedBatches)
        arguments += option("tables", tables)
        arguments += option("table-run", tableRun)
        arguments += option("threads", threads)
        arguments += option("rate", rate)
        arguments += option("insert-rows", insertRows)
        arguments += option("rows-per-event", rowsPerEvent)
        arguments += option("payload-bytes", payloadBytes)
        arguments += option("sample-seconds", sampleSeconds)
        arguments += option("timeout", timeout)
        arguments += option("decoder-profile", decoderProfile?.rawValue)
        arguments += option("applier-profile", applierProfile?.rawValue)
        arguments += option("server-profile", serverProfile?.rawValue)
        arguments += option("overlap-preparation", overlapPreparation?.rawValue)
        arguments += option("flush-on-table-change", flushOnTableChange?.rawValue)
        arguments += option("explicit-table-locks", explicitTableLocks?.rawValue)
        arguments += flag("skip-build", skipBuild)
        return .run(command: "benchmark", arguments: arguments)
    }
}

private struct BuildInputs: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "build-inputs", abstract: "Print the digest of build and fixture inputs.")
    var request: LabCLIRequest {
        let arguments: [String] = []
        return .run(command: "build-inputs", arguments: arguments)
    }
}

private struct NativeDDLSuite: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "native-ddl-suite", abstract: "Run the native DDL reference cases.")
    var request: LabCLIRequest {
        let arguments: [String] = []
        return .run(command: "native-ddl-suite", arguments: arguments)
    }
}

private struct UpstreamTests: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "upstream-tests", abstract: "Run the upstream reference checks.")
    var request: LabCLIRequest {
        let arguments: [String] = []
        return .run(command: "upstream-tests", arguments: arguments)
    }
}

private struct UbuntuSmoke: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "ubuntu-smoke", abstract: "Check the Ubuntu package.")
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing image.") var skipBuild = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += flag("skip-build", skipBuild)
        return .run(command: "ubuntu-smoke", arguments: arguments)
    }
}

private struct LiveSuite: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "live-suite", abstract: "Run the live capture reference suite.")
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing image.") var skipBuild = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += flag("skip-build", skipBuild)
        return .run(command: "live-suite", arguments: arguments)
    }
}

private struct ReverseSuite: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "reverse-suite", abstract: "Run the legacy reverse profile qualification.")
    @Option(help: "Source transaction count.") var events: Int?
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing image.") var skipBuild = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("events", events)
        arguments += flag("skip-build", skipBuild)
        return .run(command: "reverse-suite", arguments: arguments)
    }
}

private struct NativeSuite: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "native-suite", abstract: "Run positive and expected refusal cases on native MySQL.")
    @Option(help: "auto, file-position, or both (default).") var positioning: String?
    @Option(help: "transaction or autocommit. The suite requires transaction.") var workload: String?
    @Option(name: .customLong("native-engine"), help: "MyISAM or InnoDB. The suite requires MyISAM.") var nativeEngine: String?
    @Flag(name: .customLong("native-init-automatic"), help: "Initialize automatic GTID mode (native-smoke only).") var nativeInitAutomatic = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("positioning", positioning)
        arguments += option("workload", workload)
        arguments += option("native-engine", nativeEngine)
        arguments += flag("native-init-automatic", nativeInitAutomatic)
        return .run(command: "native-suite", arguments: arguments)
    }
}

private struct NativeSmoke: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "native-smoke", abstract: "Run one native replication reference case.")
    @Option(help: "auto, file-position (default: auto).") var positioning: String?
    @Option(help: "transaction or autocommit. The suite requires transaction.") var workload: String?
    @Option(name: .customLong("native-engine"), help: "MyISAM or InnoDB. The suite requires MyISAM.") var nativeEngine: String?
    @Flag(name: .customLong("native-init-automatic"), help: "Initialize automatic GTID mode (native-smoke only).") var nativeInitAutomatic = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("positioning", positioning)
        arguments += option("workload", workload)
        arguments += option("native-engine", nativeEngine)
        arguments += flag("native-init-automatic", nativeInitAutomatic)
        return .run(command: "native-smoke", arguments: arguments)
    }
}

private struct ReverseCorrectness: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "reverse-correctness", abstract: "Legacy entry point for shared reverse correctness cases.")
    @Option(help: "all, database, ddl, dml, indexes, policy, or rejections.") var slice: String?
    @Flag(name: .customLong("skip-build"), help: "Reuse the existing image.") var skipBuild = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("slice", slice)
        arguments += flag("skip-build", skipBuild)
        return .run(command: "reverse-correctness", arguments: arguments)
    }
}

private struct PackageDeb: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "package-deb", abstract: "Build a Debian package using VERSION.")
    @Option(help: "Output directory. Default: artifacts/deb.") var output: String?
    @Flag(name: .customLong("skip-build"), help: "Reuse the package image.") var skipBuild = false
    @Flag(name: .customLong("skip-verification"), help: "Do not run the package installation check.") var skipVerification = false
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments += option("output", output)
        arguments += flag("skip-build", skipBuild)
        arguments += flag("skip-verification", skipVerification)
        return .run(command: "package-deb", arguments: arguments)
    }
}

private struct VerifyEvidence: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "verify-evidence", abstract: "Verify a saved case evidence directory.")
    @Argument(help: "Case evidence directory.") var directory: String
    var request: LabCLIRequest {
        var arguments: [String] = []
        arguments.append(directory)
        return .run(command: "verify-evidence", arguments: arguments)
    }
}

private struct Catalog: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ddl-catalog", abstract: "Inspect the DDL test catalog.",
        subcommands: [CatalogCheck.self, CatalogReport.self, CatalogScan.self, CatalogUpstreamCheck.self])
}

private struct CatalogCheck: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Validate the catalog and its assertion contracts.")
    var request: LabCLIRequest {
        let arguments: [String] = ["check"]
        return .run(command: "ddl-catalog", arguments: arguments)
    }
}

private struct CatalogReport: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Report catalog coverage from saved evidence.")
    @Option(help: "markdown or json.") var format: ReportFormat = .markdown
    @Option(help: "Evidence path. Repeat this option for more paths.") var evidence: [String] = []
    var request: LabCLIRequest {
        var arguments: [String] = ["report"]
        arguments += option("format", format.rawValue)
        for value in evidence { arguments += option("evidence", value) }
        return .run(command: "ddl-catalog", arguments: arguments)
    }
}

private struct CatalogScan: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Scan upstream tests for catalog candidates.")
    @Option(name: .customLong("mysql-source"), help: "Path to the MySQL source checkout.") var mysqlSource: String?
    var request: LabCLIRequest {
        var arguments: [String] = ["scan"]
        arguments += option("mysql-source", mysqlSource)
        return .run(command: "ddl-catalog", arguments: arguments)
    }
}

private struct CatalogUpstreamCheck: LabRequestCommand {
    static let configuration = CommandConfiguration(commandName: "upstream-check", abstract: "Check catalog references against upstream source.")
    @Option(name: .customLong("mysql-source"), help: "Path to the MySQL source checkout.") var mysqlSource: String?
    var request: LabCLIRequest {
        var arguments: [String] = ["upstream-check"]
        arguments += option("mysql-source", mysqlSource)
        return .run(command: "ddl-catalog", arguments: arguments)
    }
}
