import Foundation

/// First evidence slice: named schema/data assertions. This deliberately never
/// emits full scenario verification; boundary/binlog/history contracts still need
/// dedicated instrumentation. Explicit bundles, including failures, are retained.
enum DDLCoverageEvidence {
    static let imageLabel = "org.mysql-replicator.coverage-inputs"
    static let contractPaths = ["tests/DDLCoverage/catalog.json", "tests/DDLCoverage/profiles.json", "tests/DDLCoverage/upstream.json"]

    static func hashes(root: URL, paths: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        let paths = Set(paths).sorted()
        for start in stride(from: 0, to: paths.count, by: 100) {
            let batch = Array(paths[start..<min(start + 100, paths.count)])
            let names = try batch.map { path -> String in
                try DDLCoverage.safePath(path)
                let file = root.appendingPathComponent(path)
                try require(file.resolvingSymlinksInPath().path == file.path && FileManager.default.fileExists(atPath: file.path), "missing or symlinked evidence input: \(path)")
                return file.path
            }
            let lines = try ProcessRunner(root: root).run(["openssl", "dgst", "-sha256"] + names).text.components(separatedBy: "\n")
            try require(lines.count == batch.count, "unexpected SHA256 output")
            for (path, line) in zip(batch, lines) {
                let digest = String(line.suffix(64))
                try require(digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "invalid SHA256")
                result[path] = digest
            }
        }
        return result
    }

    static func digest(_ value: Any) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ddl-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSON(value, to: directory.appendingPathComponent("value.json"))
        return try hashes(root: directory, paths: ["value.json"])["value.json"]!
    }

    /// Includes dirty/untracked relevant sources and fixture inputs; documentation
    /// and generated caches do not stale evidence. Dependency versions are locked.
    static func inputs(root: URL) throws -> [String: String] {
        var paths = ["Package.swift", "Package.resolved", "compose.yaml", "Makefile", ".dockerignore"]
        let excluded: Set<String> = [".git", ".build", ".swiftpm", "target", "__pycache__"]
        for directory in ["Sources", "rust", "Vendor", "packaging", "docker", "tests"] {
            let url = root.appendingPathComponent(directory)
            guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw LabError("missing input directory: \(directory)") }
            for case let file as URL in iterator {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if excluded.contains(file.lastPathComponent) || relative.hasPrefix("tests/DDLCoverage/") {
                    iterator.skipDescendants(); continue
                }
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                try require(info.isSymbolicLink != true, "symlinked coverage input: \(relative)")
                if info.isDirectory != true && file.pathExtension.lowercased() != "md" { paths.append(relative) }
            }
        }
        return try hashes(root: root, paths: paths)
    }

    static func runtime(_ h: NativeHarness, image: String, profileID: String, inventory: DDLCoverage.Inventory, inputDigest: String) throws -> [String: Any] {
        let runner = h.runner
        let label = try runner.run(["docker", "image", "inspect", image, "--format", "{{index .Config.Labels \"\(imageLabel)\"}}" ]).text
        try require(label == inputDigest, "runtime image inputs differ; rerun ddl-suite without --skip-build")
        guard let profile = inventory.profiles.profiles.first(where: { $0.id == profileID }) else { throw LabError("missing coverage profile") }
        var servers: [[String: Any]] = []
        for service in h.services {
            let role = service == "native" ? "native84" : service
            let expected = profile.servers.first { $0.role == role }!
            let version = try h.sql(service, "SELECT VERSION()")
            try require(version == expected.version || version.hasPrefix(expected.version + "-"), "coverage server version differs: \(role): \(version)")
            let names = ["gtid_mode", "enforce_gtid_consistency", "binlog_format", "binlog_row_image", "binlog_row_metadata", "default_storage_engine", "default_tmp_storage_engine", "disabled_storage_engines", "sql_mode", "character_set_server", "collation_server", "character_set_client", "character_set_connection", "collation_connection", "gtid_next"]
            let text = try h.sql(service, "SHOW VARIABLES WHERE Variable_name IN (" + names.map { "'" + $0 + "'" }.joined(separator: ",") + ")")
            var values: [String: String] = [:]
            for line in text.components(separatedBy: "\n") {
                let pair = line.components(separatedBy: "\t")
                if pair.count == 2 { values[pair[0].lowercased()] = pair[1] }
            }
            for setting in expected.settings where setting.basis != "query_context" {
                try require(values[setting.name] == (setting.value == "(empty)" ? "" : setting.value), "coverage profile setting differs: \(role).\(setting.name): \(values[setting.name] ?? "missing")")
            }
            let container = try h.compose(["ps", "-q", service]).text
            let actualImage = try runner.run(["docker", "inspect", container, "--format", "{{.Image}}"] ).text
            servers.append(["role": role, "version": version, "image": actualImage, "settings": values])
        }
        let binary = try runner.run(["docker", "run", "--rm", "--entrypoint", "sha256sum", image, "/usr/local/bin/mysql-replicator"]).text
        let toolchains = try runner.run(["docker", "run", "--rm", "--entrypoint", "cat", image, "/opt/packaging-evidence/toolchains.txt"]).text
        return ["profile": profileID, "servers": servers, "runtime_image": image, "build_inputs_digest": label,
                "binary_sha256": String(binary.prefix(64)), "toolchains": toolchains,
                "context_limit": "Client/server settings sampled before workload; per-event applier-session context is not qualified by this evidence slice."]
    }

    static func save(root: URL, output: URL, profile: String, inputs: [String: String], contracts: [String: String], runtime: [String: Any], results: [[String: Any]]) throws {
        let unchanged = try self.inputs(root: root) == inputs && hashes(root: root, paths: contractPaths) == contracts
        try writeJSON(runtime, to: output.appendingPathComponent("coverage-runtime.json"))
        var artifacts = ["result.json", "cases.json", "coverage-runtime.json"]
        for test in results {
            for assertion in test["assertions"] as? [[String: Any]] ?? [] {
                if let path = assertion["evidence"] as? String { artifacts.append(path) }
            }
        }
        let runner = ProcessRunner(root: root)
        let hostDigest = try harnessDigest(root: root)
        let bundle: [String: Any] = ["schema_version": 1, "kind": "ddl_named_assertions_partial_v1", "run_id": output.lastPathComponent,
            "created_at": ISO8601DateFormatter().string(from: Date()), "suite": "ddl-suite", "profile": profile,
            "git_revision": try runner.run(["git", "rev-parse", "HEAD"]).text,
            "git_dirty": !(try runner.run(["git", "status", "--porcelain"]).text.isEmpty),
            "inputs": inputs, "contract_hashes": contracts, "inputs_unchanged": unchanged,
            "harness_binary_sha256": String(hostDigest), "artifact_hashes": try hashes(root: output, paths: artifacts)]
        try writeJSON(bundle, to: output.appendingPathComponent("coverage-evidence.json"))
        try require(unchanged, "coverage inputs changed during the run; evidence cannot be used")
    }

    static func harnessDigest(root: URL) throws -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        return String(try ProcessRunner(root: root).run(["openssl", "dgst", "-sha256", executable.path]).text.suffix(64))
    }

    struct Bundle {
        let profile: String
        let stale: Bool
        let passed: Bool
        let cases: [[String: Any]]
        let origin: String
    }
    static func object(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        try require(data.count <= 4 * 1024 * 1024, "coverage JSON exceeds 4 MiB")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LabError("invalid coverage object") }
        return object
    }
    static func load(_ manifest: URL, currentInputs: [String: String], contracts: [String: String], inventory: DDLCoverage.Inventory, harnessDigest: String? = nil) throws -> Bundle {
        let root = manifest.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let data = try object(manifest)
        try require(data["schema_version"] as? Int == 1 && data["kind"] as? String == "ddl_named_assertions_partial_v1" && data["suite"] as? String == "ddl-suite", "unsupported coverage bundle")
        guard let profile = data["profile"] as? String, DDLCoverageCases.swiftProfiles.contains(profile),
              let recordedInputs = data["inputs"] as? [String: String], !recordedInputs.isEmpty,
              let recordedContracts = data["contract_hashes"] as? [String: String],
              let files = data["artifact_hashes"] as? [String: String],
              let unchanged = data["inputs_unchanged"] as? Bool,
              let hostDigest = data["harness_binary_sha256"] as? String, hostDigest.count == 64 else { throw LabError("incomplete evidence identity") }
        try require(Set(["result.json", "cases.json", "coverage-runtime.json"]).isSubset(of: Set(files.keys)), "missing required evidence artifacts")
        try require(try hashes(root: root, paths: Array(files.keys)) == files, "evidence artifact checksum mismatch")
        let runtime = try object(root.appendingPathComponent("coverage-runtime.json"))
        try require(runtime["profile"] as? String == profile && runtime["build_inputs_digest"] as? String == digest(recordedInputs), "runtime build/profile identity mismatch")
        try require((runtime["servers"] as? [[String: Any]])?.count == 3 && (runtime["binary_sha256"] as? String)?.count == 64, "missing runtime provenance")
        if recordedContracts == contracts {
            let definition = inventory.profiles.profiles.first { $0.id == profile }!
            let servers = runtime["servers"] as! [[String: Any]]
            try require(Set(servers.compactMap { $0["role"] as? String }) == Set(definition.servers.map(\.role)), "runtime server roles differ")
            for expected in definition.servers {
                guard let actual = servers.first(where: { $0["role"] as? String == expected.role }),
                      let version = actual["version"] as? String, version == expected.version || version.hasPrefix(expected.version + "-"),
                      let settings = actual["settings"] as? [String: String],
                      let image = actual["image"] as? String, image.hasPrefix("sha256:") else { throw LabError("missing or incompatible runtime server identity") }
                for setting in expected.settings where setting.basis != "query_context" {
                    try require(settings[setting.name] == (setting.value == "(empty)" ? "" : setting.value), "runtime setting differs: \(expected.role).\(setting.name)")
                }
            }
        }
        let result = try object(root.appendingPathComponent("result.json"))
        guard let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cases.json"))) as? [[String: Any]] else { throw LabError("missing case evidence") }
        var seen = Set<String>()
        for test in cases {
            guard let id = test["id"] as? String, seen.insert(id).inserted,
                  let entry = DDLCoverageCases.registry.first(where: { $0.suite == "ddl-suite" && $0.test.id == id }), entry.profiles.contains(profile),
                  let status = test["status"] as? String, ["running", "passed", "failed"].contains(status) else { throw LabError("unknown, duplicate or invalid evidence case") }
            var assertionIDs = Set<String>()
            for assertion in test["assertions"] as? [[String: Any]] ?? [] {
                guard let name = assertion["id"] as? String, DDLCoverageCases.assertions(for: id).contains(name), assertionIDs.insert(name).inserted,
                      let status = assertion["status"] as? String, ["passed", "failed"].contains(status) else { throw LabError("invalid named assertion") }
                if status == "passed" { try require((assertion["evidence"] as? String).flatMap { files[$0] } != nil, "passing assertion lacks checksummed evidence") }
            }
        }
        return Bundle(profile: profile, stale: !unchanged || recordedInputs != currentInputs || recordedContracts != contracts || (harnessDigest != nil && harnessDigest != hostDigest),
                      passed: result["result"] as? String == "passed" && result["cleanup"] as? String == "passed", cases: cases, origin: manifest.path)
    }

    static func evaluate(_ scenario: DDLCatalog.Scenario, profile: String, bundle: Bundle?) -> [String: Any] {
        let required = scenario.requiredAssertions.map(\.id).sorted()
        var status = "unverified", passed: [String] = []
        if let bundle {
            if bundle.stale { status = "stale" }
            else if let contracts = DDLCoverageCases.evidenceContracts[scenario.id] {
                let bindings = scenario.bindings.filter { $0.profiles.contains(profile) && !$0.assertionIds.isEmpty }
                let byID = Dictionary(uniqueKeysWithValues: bundle.cases.compactMap { row in (row["id"] as? String).map { ($0, row) } })
                let caseIDs = Set(bindings.flatMap(\.caseIds))
                let parentIDs = Set(bindings.compactMap(\.completionCaseId))
                let failed = !bundle.passed || caseIDs.union(parentIDs).contains { id in
                    byID[id]?["status"] as? String == "failed" || (byID[id]?["assertions"] as? [[String: Any]] ?? []).contains { $0["status"] as? String == "failed" }
                }
                let complete = caseIDs.union(parentIDs).allSatisfy { byID[$0]?["status"] as? String == "passed" }
                if failed { status = "failed" }
                else if complete {
                    for name in Set(bindings.flatMap(\.assertionIds)).sorted() {
                        guard let cases = contracts[name], !cases.isEmpty else { continue }
                        if cases.allSatisfy({ id in
                            let assertions = byID[id]?["assertions"] as? [[String: Any]] ?? []
                            return assertions.contains { $0["id"] as? String == name && $0["status"] as? String == "passed" }
                        }) { passed.append(name) }
                    }
                    if !passed.isEmpty { status = "partial" }
                }
            }
        }
        return ["profile": profile, "qualification": status, "passed_assertions": passed,
                "missing_assertions": required.filter { !passed.contains($0) }, "required_assertion_count": required.count]
    }

    static func report(_ inventory: DDLCoverage.Inventory, bundles: [Bundle]) throws -> [String: Any] {
        try require(Set(bundles.map(\.profile)).count == bundles.count, "select at most one evidence bundle per profile; do not cherry-pick between runs")
        var report = DDLCoverage.report(inventory)
        var rows = report["scenarios"] as! [[String: Any]]
        var passed = 0, required = 0, partial = 0
        for index in rows.indices {
            let scenario = inventory.catalog.scenarios.first { $0.id == rows[index]["id"] as? String }!
            let profiles = scenario.requiredProfiles.sorted().map { profile in evaluate(scenario, profile: profile, bundle: bundles.first { $0.profile == profile }) }
            rows[index]["profile_evidence"] = profiles
            let states = profiles.compactMap { $0["qualification"] as? String }
            if scenario.scope != "excluded" {
                rows[index]["qualification"] = states.contains("failed") ? "failed" : states.contains("stale") ? "stale" : states.contains("partial") ? "partial" : "unverified"
                for row in profiles {
                    passed += (row["passed_assertions"] as! [String]).count
                    required += row["required_assertion_count"] as! Int
                    if row["qualification"] as? String == "partial" { partial += 1 }
                }
            }
        }
        report["scenarios"] = rows
        report["evidence_status"] = bundles.isEmpty ? "not_loaded" : "partial_assertion_evidence_loaded"
        report["qualification_note"] = "Named schema/data assertions only; no full scenario verification. Binlog/boundary/history and per-event context remain separate gaps."
        report["assertion_summary"] = ["passed": passed, "required": required, "partial_scenario_profiles": partial, "verified_scenario_profiles": 0]
        report["selected_evidence"] = bundles.map { ["profile": $0.profile, "path": $0.origin] }
        return report
    }
}
