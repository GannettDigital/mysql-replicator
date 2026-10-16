import XCTest
@testable import ReplicatorLabCommandLine

final class LabCommandLineTests: XCTestCase {
    let profile = "mysql84-to-mysql57-myisam"
    func testHelpForEveryCommandNeedsNoRepositoryOrDatabase() throws {
        var paths: [[String]] = [[], ["test"], ["benchmark"], ["demo"], ["ddl-catalog"],
            ["build-inputs"], ["native-suite"], ["native-smoke"], ["ubuntu-smoke"],
            ["live-suite"], ["native-ddl-suite"], ["upstream-tests"], ["package-deb"],
            ["reverse-correctness"], ["reverse-suite"], ["verify-evidence"]]
        paths += ["up", "start", "stop", "status", "compare", "sql", "fail", "skip", "inspect", "resolve", "down", "legacy-down"].map { ["demo", $0] }
        paths += ["check", "report", "scan", "upstream-check"].map { ["ddl-catalog", $0] }
        for path in paths {
            guard case .help(let text) = try ReplicatorLabCommandLine.parse(path + ["--help"]) else { return XCTFail("Missing help for \(path)") }
            XCTAssertTrue(text.contains("USAGE:"), text)
            XCTAssertTrue(text.contains("replicator-lab"), text)
        }
        guard case .help = try ReplicatorLabCommandLine.parse([]) else { return XCTFail("No root help") }
        guard case .help = try ReplicatorLabCommandLine.parse(["help", "demo", "resolve"]) else { return XCTFail("No help command") }
    }
    func testOptionsProduceExistingAdapterArguments() throws {
        XCTAssertEqual(try ReplicatorLabCommandLine.parse(["test", "--profile=all", "--case", "matrix-spatial", "--case=matrix-json", "--list"]),
            .run(command: "test", arguments: ["--profile", "all", "--case", "matrix-spatial", "--case", "matrix-json", "--list"]))
        XCTAssertEqual(try ReplicatorLabCommandLine.parse(["demo", "sql", "a file.sql", "--profile", profile]),
            .run(command: "demo", arguments: ["sql", "--profile", profile, "a file.sql"]))
        XCTAssertEqual(try ReplicatorLabCommandLine.parse(["demo", "resolve", "mark-applied", "--reason", "checked target", "--profile", "mysql57-to-mysql84-innodb", "--gtids", "uuid:1"]),
            .run(command: "demo", arguments: ["resolve", "--profile", "mysql57-to-mysql84-innodb", "mark-applied", "--gtids", "uuid:1", "--reason", "checked target"]))
        XCTAssertEqual(try ReplicatorLabCommandLine.parse(["benchmark", "--profile", profile, "--events=10000", "--decoder-profile=on", "--skip-build"]),
            .run(command: "benchmark", arguments: ["--profile", profile, "--mode", "backlog", "--events", "10000", "--decoder-profile", "on", "--skip-build"]))
        XCTAssertEqual(try ReplicatorLabCommandLine.parse(["ddl-catalog", "report", "--format=json", "--evidence", "a", "--evidence", "b"]),
            .run(command: "ddl-catalog", arguments: ["report", "--format", "json", "--evidence", "a", "--evidence", "b"]))
    }
    func testParserRejectsMissingValuesAndUnknownOptions() {
        let cases = [["no-such-command"], ["test", "--profile", "unknown"], ["test", "--suite", "unknown"], ["test", "--typo"], ["test", "--case"],
            ["benchmark", "--profile", profile, "--events", "many"],
            ["benchmark", "--profile", profile, "--events", "0"],
            ["benchmark", "--profile", profile, "--decoder-profile", "yes"],
            ["demo", "sql", "--profile", profile], ["demo", "up"],
            ["demo", "up", "--profile", "unknown"], ["demo", "down", "--profile", profile, "--coverage"],
            ["demo", "resolve", "erase", "--profile", profile, "--gtids", "x:1", "--reason", "x"],
            ["ddl-catalog", "check", "--evidence", "x"], ["ddl-catalog", "report", "--format", "xml"],
            ["build-inputs", "extra"], ["package-deb", "--version", "1.0"], ["verify-evidence"]]
        for arguments in cases { XCTAssertThrowsError(try ReplicatorLabCommandLine.parse(arguments), arguments.joined(separator: " ")) }
    }
    func testEveryBenchmarkOptionReachesAdapter() throws {
        let pairs = [("tables", "2"), ("table-distribution", "hot80"), ("table-run", "10"),
            ("threads", "2"), ("rate", "50"), ("rows-per-event", "3"), ("payload-bytes", "200"),
            ("sample-seconds", "2"), ("timeout", "300"), ("insert-rows", "16"),
            ("batch-transactions", "8"), ("target-transport", "unix"), ("overlap-preparation", "on"),
            ("flush-on-table-change", "off"), ("explicit-table-locks", "off"), ("applier-profile", "on")]
        let arguments = ["benchmark", "--profile", profile, "--mode", "streaming"] + pairs.flatMap { ["--"+$0.0, $0.1] }
        guard case .run(let command, let forwarded) = try ReplicatorLabCommandLine.parse(arguments) else { return XCTFail("No benchmark request") }
        XCTAssertEqual(command, "benchmark")
        for (name, value) in pairs {
            guard let index = forwarded.firstIndex(of: "--"+name) else { XCTFail("Missing " + name); continue }
            XCTAssertEqual(forwarded[index+1], value)
        }
    }
}
