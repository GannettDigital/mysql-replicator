import XCTest

@testable import ReplicatorCommandLine

final class CommandLineTests: XCTestCase {
    func testValidationModeIsExplicitAndTyped() throws {
        for mode in ["run", "replay"] {
            XCTAssertEqual(
                try ReplicatorCommandLine.parse(["validate", "--config", "apply.yaml", "--mode", mode]),
                .validate(config: "apply.yaml", mode: mode))
        }
        for args in [
            ["validate", "--config", "apply.yaml"],
            ["validate", "--config", "apply.yaml", "--mode", "reply"],
            ["validate", "--config", "apply.yaml", "--mode", "run", "--mode", "replay"],
        ] {
            XCTAssertThrowsError(try ReplicatorCommandLine.parse(args))
        }
    }
    func testLoggingFlagsDoNotChangeRequestsAndDebugWins() throws {
        let base = ["run", "--config", "/unused.yaml"]
        let expected = try ReplicatorCommandLine.parse(base)
        for (flags, level) in [
            ([], "warning"), (["--verbose"], "info"), (["--debug"], "debug"), (["--debug", "--verbose"], "debug"),
        ] {
            let invocation = try ReplicatorCommandLine.parseInvocation(base + flags)
            XCTAssertEqual(invocation.request, expected)
            XCTAssertEqual(invocation.logLevel, level)
        }
        let literal = try ReplicatorCommandLine.parseInvocation([
            "recovery", "resolve", "retry", "--config", "x.yaml", "--gtids", "uuid:1", "--reason=--debug",
        ])
        XCTAssertEqual(literal.logLevel, "warning")
        XCTAssertEqual(try ReplicatorCommandLine.parseInvocation(["--verbose"] + base).logLevel, "info")
        XCTAssertEqual(try ReplicatorCommandLine.parseInvocation(["--verbose"] + base + ["--debug"]).logLevel, "debug")
        XCTAssertThrowsError(try ReplicatorCommandLine.parse(base + ["--debug", "--debug"]))
        guard case .help = try ReplicatorCommandLine.parse(["run", "--debug", "--help"]) else {
            return XCTFail("No help")
        }
    }
    func testHelpNeedsNoConfigurationOrDatabase() throws {
        let paths = [
            [], ["run"], ["fetch"], ["replay"], ["support-bundle"], ["inspect"],
            ["inspect-relay"], ["blackhole"], ["skip"], ["ctl"], ["ctl", "status"],
            ["ctl", "stop"], ["ctl", "reload"], ["recovery"], ["recovery", "inspect"], ["recovery", "resolve"],
            ["config-help"],
        ]
        for path in paths {
            guard case .help(let text) = try ReplicatorCommandLine.parse(path + ["--help"]) else {
                return XCTFail("No help for \(path)")
            }
            XCTAssertTrue(text.contains("USAGE:"), text)
            XCTAssertTrue(text.contains("mysql-replicator"), text)
        }
        guard case .help = try ReplicatorCommandLine.parse([]) else { return XCTFail("No root help") }
        XCTAssertEqual(try ReplicatorCommandLine.parse(["--version"]), .version)
    }
    func testCommandsProduceRequestsWithoutReadingConfiguration() throws {
        let config = "/does/not/exist.yaml"
        let cases: [([String], CLIRequest)] = [
            (["config-help"], .configurationHelp(command: nil, section: nil)),
            (
                ["config-help", "--command", "replay", "--section", "target"],
                .configurationHelp(command: "replay", section: "target")
            ),
            (["run", "--config", config], .apply(config: config, initialize: false, offline: false)),
            (["replay", "--initialize", "--config", config], .apply(config: config, initialize: true, offline: true)),
            (["run", "--config=" + config, "--initialize"], .apply(config: config, initialize: true, offline: false)),
            (["fetch", "--config", config], .fetch(config: config)),
            (["support-bundle", "--config", config], .supportBundle(config: config)),
            (["ctl", "status", "--config", config], .control(config: config, action: "status", timeout: 60)),
            (
                ["ctl", "stop", "--timeout", "300", "--config", config],
                .control(config: config, action: "stop", timeout: 300)
            ),
            (["ctl", "reload", "--config", config], .control(config: config, action: "reload", timeout: 60)),
            (["recovery", "inspect", "--config", config], .recoveryInspect(config: config)),
            (["skip", "uuid:1-3", "--config", config], .skip(config: config, gtids: "uuid:1-3")),
            (["blackhole", "--source-config", config], .blackhole(config: config)),
            (
                ["inspect-relay", "relay.frames", "--include-raw"],
                .inspectRelay(file: "relay.frames", includeRaw: true)
            ),
            (
                ["inspect", "binlog.000001"],
                .inspectFile(file: "binlog.000001", schema: nil, includeRaw: false, binlogFile: nil)
            ),
            (
                [
                    "inspect", "--schema", "history.json", "data.binlog", "--transactions", "--binlog-file",
                    "binlog.000003", "--include-raw",
                ],
                .inspectFile(file: "data.binlog", schema: "history.json", includeRaw: true, binlogFile: "binlog.000003")
            ),
            (
                ["inspect", "--transactions", "--source-config", config, "--include-raw"],
                .inspectSource(config: config, transactions: true, includeRaw: true)
            ),
        ]
        for (args, request) in cases {
            XCTAssertEqual(try ReplicatorCommandLine.parse(args), request, args.joined(separator: " "))
        }
        for action in ["mark-applied", "retry", "skip"] {
            XCTAssertEqual(
                try ReplicatorCommandLine.parse([
                    "recovery", "resolve", action, "--config", config, "--gtids", "uuid:1", "--reason",
                    "checked target",
                ]),
                .recoveryResolve(config: config, action: action, gtids: "uuid:1", reason: "checked target"))
        }
    }

    func testOptionLikeValuesUseEqualsSyntax() throws {
        for value in ["--config", "--reason", "--version"] {
            let args = ["recovery", "resolve", "retry", "--config", "a.yaml", "--gtids", "uuid:1"]
            XCTAssertEqual(
                try ReplicatorCommandLine.parse(args + ["--reason=" + value]),
                .recoveryResolve(config: "a.yaml", action: "retry", gtids: "uuid:1", reason: value))
            // ArgumentParser rejects an option token as a separate value before
            // the duplicate check runs. Quoting does not change argv tokens.
            XCTAssertThrowsError(try ReplicatorCommandLine.parse(args + ["--reason", value])) { error in
                XCTAssertTrue(String(describing: error).contains("Missing value"))
            }
        }
    }

    func testInvalidRequestsFailBeforeExecution() {
        let invalid = [
            ["unknown"], ["ctl"], ["recovery"], ["--version", "run", "--config", "a.yaml"], ["run"],
            ["run", "--config"], ["run", "--config", "a.yaml", "extra"],
            ["run", "--config", "a.yaml", "--typo"], ["run", "--config", ""],
            ["replay", "--config", "a.yaml", "--stop-after-gtids", "uuid:1"],
            ["fetch", "--config", "a.yaml", "--initialize"], ["support-bundle", "--config", "a.yaml", "--initialize"],
            ["ctl", "pause", "--config", "a.yaml"], ["ctl", "stop", "--config", "a.yaml", "--timeout", "0"],
            ["ctl", "stop", "--config", "a.yaml", "--timeout", "86401"],
            ["ctl", "stop", "--config", "a.yaml", "--timeout", "abc"],
            ["recovery", "inspect", "--config", "a.yaml", "--gtids", "uuid:1"],
            ["recovery", "resolve", "invalid", "--config", "a.yaml", "--gtids", "uuid:1", "--reason", "checked"],
            ["recovery", "resolve", "retry", "--config", "a.yaml", "--gtids", "uuid:1"],
            ["inspect"], ["inspect", "file", "--source-config", "a.yaml"], ["inspect", "file", "--transactions"],
            ["inspect", "file", "--binlog-file", "binlog.000001"],
            ["inspect", "--source-config", "a.yaml", "--schema", "history.json"],
            ["inspect", "--source-config", "a.yaml", "--binlog-file", "binlog.000001"],
            ["run", "--config", "a.yaml", "--config", "b.yaml"],
            ["replay", "--config", "a.yaml", "--initialize", "--initialize"],
            ["inspect", "file", "--include-raw", "--include-raw"],
        ]
        for args in invalid {
            XCTAssertThrowsError(try ReplicatorCommandLine.parse(args), args.joined(separator: " ")) { error in
                XCTAssertTrue(error is CLIParseError)
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }

    func testHelpDescribesOperationalLimits() throws {
        for (args, words) in [
            (["replay", "--help"], "without source access"),
            (["ctl", "reload", "--help"], "source.stopAfterGTIDs"),
            (["support-bundle", "--help"], "does not upload"),
            (["recovery", "resolve", "--help"], "mark-applied"),
            (["recovery", "--help"], "do not connect to MySQL"),
            (["recovery", "resolve", "--help"], "permits retry only"),
            (["recovery", "resolve", "--help"], "without --initialize"),
            (["help", "ctl", "stop"], "graceful drain"),
        ] {
            guard case .help(let text) = try ReplicatorCommandLine.parse(args) else { return XCTFail("No help") }
            XCTAssertTrue(text.contains(words), text)
        }
    }

}
