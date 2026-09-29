import Foundation

public enum Upstream {
    public static let revision = "374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c"
    public static func qualify(root: URL) throws {
        let runner = ProcessRunner(root: root)
        let source = root.appendingPathComponent(".upstream/rust_mysql_common")
        let output = root.appendingPathComponent("artifacts/upstream/" + runID())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = ["revision": revision, "result": "failed", "swift_abi_qualification": "pending"]
        do {
            if !FileManager.default.fileExists(atPath: source.path) {
                _ = try runner.run(["git", "clone", "--filter=blob:none", "--no-checkout",
                                    "https://github.com/blackbeam/rust_mysql_common", source.path], timeout: 300)
                _ = try runner.run(["git", "-C", source.path, "checkout", "--detach", revision], timeout: 300)
            }
            try require(runner.run(["git", "-C", source.path, "rev-parse", "HEAD"]).text == revision, "upstream revision mismatch")
            _ = try runner.run(["git", "-C", source.path, "diff", "--exit-code", "HEAD"])
            let lock = root.appendingPathComponent("tests/Upstream/Cargo.lock")
            try Data(contentsOf: lock).write(to: source.appendingPathComponent("Cargo.lock"))
            report["rust_version"] = try runner.run(["rustc", "--version"]).text
            report["lock_sha256"] = try runner.run(["openssl", "dgst", "-sha256", lock.path]).text.components(separatedBy: " ").last
            let result = try runner.run(["cargo", "test", "--manifest-path", source.appendingPathComponent("Cargo.toml").path,
                                         "--locked", "--no-default-features", "--features", "test,binlog,flate2/rust_backend",
                                         "--lib", "binlog", "--target-dir", root.appendingPathComponent(".build/upstream-rust").path],
                                        timeout: 1800, checked: false)
            try (result.stdout + result.stderr).write(to: output.appendingPathComponent("tests.log"))
            try require(result.status == 0 && result.text.contains("26 passed; 0 failed; 0 ignored"), "explicit upstream binlog suite did not pass all 26 tests")
            let fixtureRoot = source.appendingPathComponent("test-data/binlogs")
            let files = try FileManager.default.contentsOfDirectory(at: fixtureRoot, includingPropertiesForKeys: [.isRegularFileKey]).sorted { $0.path < $1.path }
            var catalog: [[String: Any]] = []
            for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let sha = try runner.run(["openssl", "dgst", "-sha256", file.path]).text.components(separatedBy: " ").last ?? ""
                catalog.append(["path": "test-data/binlogs/" + file.lastPathComponent, "sha256": sha,
                                "origin": "https://github.com/blackbeam/rust_mysql_common/blob/\(revision)/test-data/binlogs/\(file.lastPathComponent)",
                                "classification": "upstream_fixture_swift_coverage_pending",
                                "license": "Repository MIT/Apache-2.0; individual fixture provenance must be reviewed before redistribution"])
            }
            try writeJSON(catalog, to: output.appendingPathComponent("fixture-catalog.json"))
            report["fixture_count"] = catalog.count
            report["passed_tests"] = 26
            report["result"] = "passed"
        } catch {
            report["error"] = String(describing: error)
            try writeJSON(report, to: output.appendingPathComponent("result.json"))
            throw LabError("\(error); evidence: \(output.path)")
        }
        try writeJSON(report, to: output.appendingPathComponent("result.json"))
        print("PASS upstream binlog suite; evidence: \(output.path)")
    }
}
