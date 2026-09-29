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
          upstream-tests
          verify-evidence <case-evidence-directory>
        native-suite verifies positive and expected rejection cases; smoke retains
        nonzero exit for observed rejection. MYSQLBINLOG selects a MySQL 8.4 client.
        Source ON/ON and targets OFF_PERMISSIVE/WARN are fixed for qualification.
        """)
        return 0
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("compose.yaml").path), "run from the repository root")
    if command == "verify-evidence" {
        try require(args.count == 1, "verify-evidence requires one case directory")
        try EvidenceVerification.verify(root: root, directory: URL(fileURLWithPath: args[0], relativeTo: root).standardizedFileURL)
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
