import Foundation
import ReplicatorLabCommandLine
import ReplicatorLabCore

func main() throws -> Int32 {
    let request = try ReplicatorLabCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
    if case .help(let text) = request {
        print(text)
        return 0
    }
    guard case .run(let command, var args) = request else { return 0 }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    try require(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("compose.yaml").path),
        "run from the repository root")
    if command == "build-inputs" {
        try require(args.isEmpty, "build-inputs accepts no arguments")
        print(try LabBuild.inputDigest(root: root))
        return 0
    }
    if command == "demo" {
        try LabDemo.run(root: root, arguments: args)
        return 0
    }
    if command == "test" {
        try LabTests.run(root: root, arguments: args)
        return 0
    }
    if command.hasPrefix("demo-") || command.hasPrefix("reverse-demo-") {
        throw LabError(
            "use demo ACTION --profile PROFILE, or test --suite demo --profile PROFILE; see docs/TEST_LAB.md")
    }
    if command == "benchmark-capture" {
        throw LabError("use benchmark --profile mysql84-to-mysql57-myisam --mode capture")
    }
    if command == "benchmark" {
        try LabBenchmark.run(root: root, arguments: args)
        return 0
    }
    if command == "ddl-catalog" {
        try DDLCoverage.run(root: root, arguments: args)
        return 0
    }
    if command == "native-ddl-suite" {
        try require(args.isEmpty, "native-ddl-suite accepts no arguments")
        try NativeDDLQualification.run(root: root)
        return 0
    }
    if command == "reverse-correctness" {
        try SharedCorrectness.run(root: root, arguments: args)
        return 0
    }
    if command == "reverse-suite" {
        let build = !args.contains("--skip-build")
        args.removeAll { $0 == "--skip-build" }
        var events = 100
        if !args.isEmpty {
            guard args.count == 2, args[0] == "--events", let n = Int(args[1]) else {
                throw LabError("reverse-suite accepts --skip-build and --events N")
            }
            events = n
        }
        try ReverseQualification.run(root: root, build: build, events: events)
        return 0
    }
    if command == "live-suite" {
        try require(args.isEmpty || args == ["--skip-build"], "live-suite accepts only --skip-build")
        try LiveQualification.run(root: root, build: args.isEmpty)
        return 0
    }
    if command == "ubuntu-smoke" {
        try require(args.isEmpty || args == ["--skip-build"], "ubuntu-smoke accepts only --skip-build")
        try UbuntuQualification.run(root: root, build: args.isEmpty)
        return 0
    }
    if command == "verify-evidence" {
        try require(args.count == 1, "verify-evidence requires one case directory")
        try EvidenceVerification.verify(
            root: root, directory: URL(fileURLWithPath: args[0], relativeTo: root).standardizedFileURL)
        return 0
    }
    if command == "package-deb" {
        try DebianPackaging.run(root: root, arguments: args)
        return 0
    }
    var config = NativeCase()
    var positioning = command == "native-suite" ? "both" : "auto"
    while !args.isEmpty {
        let flag = args.removeFirst()
        if flag == "--native-init-automatic" {
            config.initAutomatic = true
            continue
        }
        guard !args.isEmpty else { throw LabError("missing value for \(flag)") }
        let value = args.removeFirst()
        switch flag {
        case "--positioning":
            try require(["auto", "file-position", "both"].contains(value), "invalid positioning")
            positioning = value
        case "--workload":
            try require(["transaction", "autocommit"].contains(value), "invalid workload")
            config.transaction = value == "transaction"
        case "--native-engine":
            try require(["MyISAM", "InnoDB"].contains(value), "invalid native engine")
            config.nativeEngine = value
        default: throw LabError("unknown option \(flag)")
        }
    }
    switch command {
    case "native-smoke":
        try require(positioning != "both", "smoke takes one positioning mode")
        config.autoPosition = positioning == "auto"
        _ = try NativeHarness(root: root, config: config).run()
        return config.rejects ? 1 : 0
    case "native-suite":
        try require(
            config.nativeEngine == "MyISAM" && !config.initAutomatic && config.transaction,
            "suite uses fixed positive and negative MyISAM cases")
        let output = root.appendingPathComponent("artifacts/native-suite/suite-" + runID() + ".json")
        var cases: [[String: Any]] = []
        var passed = true
        for auto in positioning == "both" ? [false, true] : [positioning == "auto"] {
            for transaction in [false, true] {
                var test = NativeCase()
                test.autoPosition = auto
                test.transaction = transaction
                let harness = NativeHarness(root: root, config: test)
                do {
                    let result = try harness.run()
                    cases.append([
                        "case": test.name, "assertions": "passed",
                        "native_observed_outcome": result["native_observed_outcome"]!, "evidence": harness.output.path,
                    ])
                } catch {
                    passed = false
                    cases.append([
                        "case": test.name, "assertions": "failed", "error": String(describing: error),
                        "evidence": harness.output.path,
                    ])
                }
            }
        }
        try writeJSON(
            [
                "schema_version": 1, "result": passed ? "passed" : "failed",
                "cases": cases, "swift_apply": "pending", "phase_1": "in_progress",
            ], to: output)
        print("Suite \(passed ? "passed" : "failed"); \(output.path)")
        return passed ? 0 : 1
    case "upstream-tests":
        try Upstream.qualify(root: root)
        return 0
    default: throw LabError("unknown command: \(command)")
    }
}

do { exit(try main()) } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
