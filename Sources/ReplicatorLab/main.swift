import Foundation
import ReplicatorLabCore

func main() throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.isEmpty ? "--help" : args.removeFirst()
    if command == "--help" {
        print("""
        replicator-lab: repository automation (run from the repository root)
          native-suite [--positioning auto|file-position|both]
          native-smoke [--positioning auto|file-position] [--workload transaction|autocommit]
                       [--native-engine MyISAM|InnoDB] [--native-init-automatic]
          ubuntu-smoke [--skip-build]
          live-suite [--skip-build]
          dml-suite [--skip-build] [--slice all|basic|matrix|extended] [--positioning both|gtid|file-position] [--list]
          ddl-suite [--skip-build] [--slice all|basic|modify-index|database|ordered|filters|compatibility]
                    [--case ID ...] [--positioning both|gtid|file-position] [--list]
          native-ddl-suite
          benchmark-capture [--skip-build] [--events N] [--rate N] [--decoder-profile on|off]
          benchmark [--tables N] [--table-distribution uniform|hot80] [--table-run N] [--skip-build] [--events N] [--threads N] [--rate N]
                    [--target-transport tcp-tls|unix-tls|unix]
                    [--insert-rows N] [--overlap-preparation on|off] [--flush-on-table-change on|off]
                    [--explicit-table-locks on|off]
                    [--batch-transactions N] [--decoder-profile on|off] [--applier-profile on|off]
                    [--workload insert|mixed] [--rows-per-event N] [--payload-bytes N]
                    [--sample-seconds N] [--timeout N]
          ddl-catalog check
          ddl-catalog report [--format markdown|json] [--evidence PATH ...]
          ddl-catalog upstream-check [--mysql-source PATH]
          ddl-catalog scan [--mysql-source PATH]
          demo-up [--skip-build]    # prepare stack/config and an idle applier container
          demo-start               # launch mysql-replicator inside the running container
          demo-status              # containers, native status, live SQLite and diagnostics
          demo-sql FILE            # execute a SQL file on the demo source
          demo-compare [--expect-blocked]
          demo-fail                # run prepared failure and verify both appliers stopped
          demo-down                # archive evidence and delete only this disposable stack
          demo-suite [--skip-build]
          upstream-tests
          package-deb [--output DIR] [--skip-build] [--skip-verification]
          reverse-correctness [--skip-build] [--slice all|database|ddl|dml|indexes|policy|rejections]
          reverse-suite [--skip-build] [--events N] # 5.7 InnoDB → 8.4 InnoDB
          reverse-demo-up [--skip-build]
          reverse-demo-start | reverse-demo-stop | reverse-demo-status | reverse-demo-compare
          reverse-demo-sql FILE | reverse-demo-inspect | reverse-demo-down
          reverse-demo-resolve ACTION --gtids GTID_SET --reason TEXT
          reverse-demo-suite [--skip-build]
          verify-evidence <case-evidence-directory>
        native-suite verifies positive and expected rejection cases; smoke retains
        nonzero exit for observed rejection. MYSQLBINLOG selects a MySQL 8.4 client.
        Source ON/ON and targets OFF_PERMISSIVE/WARN are fixed for qualification.
        """)
        return 0
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("compose.yaml").path), "run from the repository root")
    if command.hasPrefix("reverse-demo-") {
        try ReverseDemo.run(root:root,command:command,arguments:args); return 0
    }
    if command.hasPrefix("demo-") {
        try DemoSession.run(root: root, command: command, arguments: args); return 0
    }
    if command == "benchmark-capture" {
        try CaptureBenchmark.run(root:root,arguments:args); return 0
    }
    if command == "benchmark" {
        try PerformanceBenchmark.run(root: root, arguments: args); return 0
    }
    if command == "ddl-catalog" {
        try DDLCoverage.run(root: root, arguments: args); return 0
    }
    if command == "native-ddl-suite" {
        try require(args.isEmpty,"native-ddl-suite accepts no arguments")
        try NativeDDLQualification.run(root:root); return 0
    }
    if command == "dml-suite" || command == "ddl-suite" {
        let ddl = command == "ddl-suite"
        let selection = try SuiteSelection(arguments: args, ddl: ddl)
        if selection.list { selection.describe(ddl: ddl); return 0 }
        try DMLQualification.run(root: root, build: selection.build, ddl: ddl, selection: selection)
        return 0
    }
    if command == "reverse-correctness" {
        try ReverseCorrectness.run(root:root,arguments:args); return 0
    }
    if command == "reverse-suite" {
        let build = !args.contains("--skip-build")
        args.removeAll { $0 == "--skip-build" }
        var events = 100
        if !args.isEmpty {
            guard args.count == 2, args[0] == "--events", let n = Int(args[1]) else { throw LabError("reverse-suite accepts --skip-build and --events N") }
            events = n
        }
        try ReverseQualification.run(root:root,build:build,events:events)
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
        try EvidenceVerification.verify(root: root, directory: URL(fileURLWithPath: args[0], relativeTo: root).standardizedFileURL)
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
        if flag == "--native-init-automatic" { config.initAutomatic = true; continue }
        guard !args.isEmpty else { throw LabError("missing value for \(flag)") }
        let value = args.removeFirst()
        switch flag {
        case "--positioning":
            try require(["auto", "file-position", "both"].contains(value), "invalid positioning")
            positioning = value
        case "--workload":
            try require(["transaction", "autocommit"].contains(value), "invalid workload"); config.transaction = value == "transaction"
        case "--native-engine":
            try require(["MyISAM", "InnoDB"].contains(value), "invalid native engine"); config.nativeEngine = value
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
        try require(config.nativeEngine == "MyISAM" && !config.initAutomatic && config.transaction, "suite uses fixed positive and negative MyISAM cases")
        let output = root.appendingPathComponent("artifacts/native-suite/suite-" + runID() + ".json")
        var cases: [[String: Any]] = []
        var passed = true
        for auto in positioning == "both" ? [false, true] : [positioning == "auto"] {
            for transaction in [false, true] {
                var test = NativeCase(); test.autoPosition = auto; test.transaction = transaction
                let harness = NativeHarness(root: root, config: test)
                do {
                    let result = try harness.run()
                    cases.append(["case": test.name, "assertions": "passed", "native_observed_outcome": result["native_observed_outcome"]!, "evidence": harness.output.path])
                } catch {
                    passed = false
                    cases.append(["case": test.name, "assertions": "failed", "error": String(describing: error), "evidence": harness.output.path])
                }
            }
        }
        try writeJSON(["schema_version": 1, "result": passed ? "passed" : "failed",
                       "cases": cases, "swift_apply": "pending", "phase_1": "in_progress"], to: output)
        print("Suite \(passed ? "passed" : "failed"); \(output.path)")
        return passed ? 0 : 1
    case "upstream-tests":
        try Upstream.qualify(root: root)
        return 0
    default: throw LabError("unknown command: \(command)")
    }
}

do { exit(try main()) }
catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(2) }
