import Foundation

/// Executable path coverage, separate from the DDL qualification catalog.
enum CodeCoverage {
    static let image = "mysql-replicator:coverage"
    static func build(_ runner: ProcessRunner, labels: [String] = []) throws {
        _ = try runner.run(["docker", "build", "--progress=plain", "--platform", "linux/amd64",
                            "-f", "docker/coverage/Dockerfile", "-t", image] + labels + ["."], timeout: 3600,
                           onOutput: { FileHandle.standardError.write($0) })
    }
    static func validate(_ runner: ProcessRunner, image: String, enabled: Bool) throws {
        let marker = try runner.run(["docker", "image", "inspect", image, "--format",
                                    "{{index .Config.Labels \"org.mysql-replicator.code-coverage\"}}"] ).text
        try require((marker == "swift") == enabled, "image instrumentation does not match requested coverage mode")
    }
    static func environment(enabled: Bool, label: String) -> [String] {
        enabled ? ["-e", "LLVM_PROFILE_FILE=/evidence/code-coverage/\(label)/%h-%p-%m.profraw"] : []
    }
    static func collect(_ runner: ProcessRunner, image: String, volume: String, label: String, allowEmpty: Bool = false) throws {
        _ = try runner.run(["docker", "run", "--rm", "--platform", "linux/amd64", "--network", "none",
                            "--mount", "type=volume,src=\(volume),dst=/evidence", "--entrypoint", "python3", image,
                            "/workspace/tools/code_coverage.py", "harness", "--profiles", "/evidence/code-coverage",
                            "--label", label] + (allowEmpty ? ["--allow-empty"] : []), timeout: 600,
                           onOutput: { FileHandle.standardError.write($0) })
    }
}
