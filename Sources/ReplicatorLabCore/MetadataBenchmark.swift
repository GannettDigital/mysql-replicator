import Foundation

/// Focused metadata measurements use the same profile names and transport
/// choices as backlog tests. The Python driver owns only disposable containers.
enum MetadataBenchmark {
    struct Options {
        var binary = ""
        var tables = 8, events = 128, targetRTT = 20, foreignKeyGroupSize = 0
        var transport = "sql"
        init(profile: LabProfile, arguments: [String]) throws {
            var args = arguments.makeIterator()
            var seen = Set<String>()
            while let flag = args.next() {
                try require(seen.insert(flag).inserted, "duplicate discovery option: " + flag)
                guard let value = args.next() else { throw LabError("missing discovery option value: " + flag) }
                switch flag {
                case "--binary": binary = value
                case "--dml-transport": transport = value
                case "--tables", "--events", "--target-rtt-ms", "--foreign-key-group-size":
                    guard let number = Int(value) else { throw LabError("expected integer for " + flag) }
                    switch flag {
                    case "--tables": tables = number
                    case "--events": events = number
                    case "--target-rtt-ms": targetRTT = number
                    default: foreignKeyGroupSize = number
                    }
                default: throw LabError("unsupported discovery option: " + flag)
                }
            }
            try require(!binary.isEmpty, "discovery requires --binary PATH; build the local applier first")
            try require(
                (1...6_000).contains(tables) && (tables...100_000).contains(events),
                "discovery requires 1...6000 tables and table-count...100000 events")
            try require((0...1000).contains(targetRTT), "target-rtt-ms must be 0...1000")
            try require(["sql", "binlog"].contains(transport), "DML transport must be sql or binlog")
            try require(
                foreignKeyGroupSize == 0
                    || (foreignKeyGroupSize >= 2 && foreignKeyGroupSize <= min(tables, 64)
                        && profile.transactionalTarget),
                "FK groups require an InnoDB target and size 2...min(table count, 64)")
        }
    }
    static func run(root: URL, profile: LabProfile, arguments: [String]) throws {
        _ = try Options(profile: profile, arguments: arguments)
        let output = root.appendingPathComponent("artifacts/metadata-benchmark/" + profile.rawValue + "/" + runID())
        _ = try ProcessRunner(root: root).run(
            [
                "python3", "tools/metadata-benchmark/benchmark.py", "--profile", profile.rawValue,
                "--output", output.path,
            ] + arguments, timeout: 1800,
            onOutput: { FileHandle.standardError.write($0) })
    }
}
