import Foundation

/// Static research tooling, never an MTR interpreter or a coverage qualifier.
/// Include lookup follows client/mysqltest.cc::open_file: including directory,
/// then mysql-test basedir. Branches, variables and generated files are not run.
enum DDLUpstreamInspection {
    final class Checkout {
        let root: URL
        let revision: String
        let runner: ProcessRunner
        let tracked: Set<String>
        private var texts: [String: String] = [:]
        private lazy var byDirectory = Dictionary(grouping: tracked) { ($0 as NSString).deletingLastPathComponent }

        func companions(_ path: String) -> [String] {
            let directory = (path as NSString).deletingLastPathComponent
            let suite = directory.hasSuffix("/t") ? String(directory.dropLast(2)) : directory
            let defaults = tracked.contains("mysql-test/include/default_my.cnf") ? ["mysql-test/include/default_my.cnf"] : []
            let nearby = Set((byDirectory[directory] ?? []) + (byDirectory[suite + "/r"] ?? []) + (byDirectory[suite] ?? []) + defaults)
            return DDLUpstreamInspection.companions(path, tracked: nearby)
        }

        init(root: URL, revision: String) throws {
            self.root = root.standardizedFileURL.resolvingSymlinksInPath()
            self.revision = revision
            try require(FileManager.default.fileExists(atPath: self.root.path), "missing MySQL checkout: \(root.path); clone the pinned source explicitly")
            runner = ProcessRunner(root: self.root)
            let top = try runner.run(["git", "rev-parse", "--show-toplevel"]).text
            try require(URL(fileURLWithPath: top).resolvingSymlinksInPath() == self.root, "MySQL source must be the Git checkout root")
            let head = try runner.run(["git", "rev-parse", "HEAD"]).text
            try require(head == revision, "MySQL revision mismatch: expected \(revision), found \(head)")
            try require(try runner.run(["git", "status", "--porcelain", "--untracked-files=normal"]).stdout.isEmpty, "MySQL checkout is dirty; use a clean pinned checkout (no automatic reset)")
            let files = try runner.run(["git", "ls-tree", "-r", "--name-only", "-z", "HEAD"]).stdout
            tracked = Set(String(decoding: files, as: UTF8.self).split(separator: "\0").map(String.init))
        }

        func file(_ path: String) throws -> URL {
            try DDLCoverage.safePath(path)
            try require(tracked.contains(path), "missing or untracked upstream file: \(path)")
            let url = root.appendingPathComponent(path)
            let resolved = url.resolvingSymlinksInPath()
            try require(resolved.path == url.path && resolved.path.hasPrefix(root.path + "/"), "upstream symlink/path escape: \(path)")
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            try require(values.isRegularFile == true && (values.fileSize ?? Int.max) <= 16 * 1024 * 1024, "upstream file is not a bounded regular file: \(path)")
            return url
        }

        func text(_ path: String) throws -> String {
            if let cached = texts[path] { return cached }
            // MTR contains intentional non-UTF8 SQL bytes; ASCII directives survive replacement.
            let value = String(decoding: try Data(contentsOf: file(path)), as: UTF8.self)
            texts[path] = value
            return value
        }

        func hashes(_ paths: [String]) throws -> [String: String] {
            let paths = Set(paths).sorted()
            var result: [String: String] = [:]
            // Match existing lab tooling; batch files to avoid one process per include.
            for start in stride(from: 0, to: paths.count, by: 100) {
                let batch = Array(paths[start..<min(start + 100, paths.count)])
                let urls = try batch.map { try file($0).path }
                let lines = try runner.run(["openssl", "dgst", "-sha256"] + urls).text.components(separatedBy: "\n")
                try require(lines.count == batch.count, "unexpected openssl digest output")
                for (path, line) in zip(batch, lines) {
                    let digest = String(line.suffix(64))
                    try require(digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "invalid SHA256 output for \(path)")
                    result[path] = digest
                }
            }
            return result
        }

        func unchanged() throws {
            try require(try runner.run(["git", "rev-parse", "HEAD"]).text == revision, "MySQL revision changed during inspection")
            try require(try runner.run(["git", "status", "--porcelain", "--untracked-files=normal"]).stdout.isEmpty, "MySQL checkout changed during inspection")
        }
    }

    struct Include: Equatable {
        let line: Int
        let expression: String
        let path: String?
        let issue: String?
        var json: [String: Any] {
            ["line": line, "expression": expression, "path": path as Any? ?? NSNull(),
             "issue": issue as Any? ?? NSNull(), "execution": "not_evaluated"]
        }
    }

    static func includes(_ text: String, path: String, tracked: Set<String>) -> [Include] {
        let pattern = #"^\s*(?:--\s*)?source\s+(.+?)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            var expression = String(line[range]).trimmingCharacters(in: .whitespaces)
            if let comment = expression.range(of: #"\s+#"#, options: .regularExpression) { expression = String(expression[..<comment.lowerBound]) }
            if expression.hasSuffix(";") { expression.removeLast() }
            expression = expression.trimmingCharacters(in: .whitespaces)
            guard expression.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil,
                  (try? DDLCoverage.safePath(expression)) != nil else {
                return Include(line: index + 1, expression: expression, path: nil, issue: "dynamic_or_unsupported_include")
            }
            let parent = (path as NSString).deletingLastPathComponent
            let candidates = [parent + "/" + expression, "mysql-test/" + expression]
            guard let resolved = candidates.first(where: tracked.contains) else {
                return Include(line: index + 1, expression: expression, path: nil, issue: "missing_literal_include")
            }
            return Include(line: index + 1, expression: expression, path: resolved, issue: nil)
        }
    }

    /// A conservative superset of sidecars from mtr_cases.pm: test/server options,
    /// configuration, combinations, hooks and results. Wrapper tests (including
    /// engine/protocol result variants) remain separate candidates.
    static func companions(_ path: String, tracked: Set<String>) -> [String] {
        guard path.hasSuffix(".test") else { return [] }
        let directory = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let suite = directory.hasSuffix("/t") ? String(directory.dropLast(2)) : directory
        return tracked.filter { item in
            let parent = (item as NSString).deletingLastPathComponent
            let name = (item as NSString).lastPathComponent
            if item == "mysql-test/include/default_my.cnf" { return true }
            if parent == suite && ["suite.opt", "my.cnf", "combinations", "suite.pm"].contains(name) { return true }
            if parent == directory {
                if name == "suite.opt" || [".opt", ".cnf", ".combinations"].contains(where: { name == stem + $0 }) { return true }
                if name.hasPrefix(stem + "-") && [".opt", ".sh"].contains(where: name.hasSuffix) { return true }
            }
            return (parent == suite + "/r" || parent == directory) && name == stem + ".result"
        }.sorted()
    }

    static func validateLocator(_ reference: DDLUpstream.Reference, text: String) throws {
        let lines = text.components(separatedBy: "\n")
        let location = reference.locator
        try require(location.startLine > 0 && location.endLine >= location.startLine && location.endLine <= lines.count, "\(reference.id): locator outside file")
        let section = lines[(location.startLine - 1)..<location.endLine].joined(separator: "\n")
        let matches = section.components(separatedBy: location.anchor).count - 1
        try require(matches == 1, "\(reference.id): locator anchor must match once inside declared range; found \(matches)")
    }

    static func graph(_ paths: [String], checkout: Checkout) throws -> [String: [Include]] {
        var result: [String: [Include]] = [:]
        var pending = paths.sorted()
        while let path = pending.popLast() {
            guard result[path] == nil else { continue }
            try require(result.count < 20_000, "include graph exceeds 20000 files")
            let edges = includes(try checkout.text(path), path: path, tracked: checkout.tracked)
            result[path] = edges
            pending += edges.compactMap(\.path).filter { result[$0] == nil }
        }
        return result
    }

    static func check(_ upstream: DDLUpstream, repository: DDLUpstream.Repository, checkout: Checkout) throws -> [String: Any] {
        let refs = upstream.references.filter { $0.repository == repository.id }
        let byID = Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0) })
        let digests = try checkout.hashes(refs.map(\.path))
        let mtr = refs.filter { ["test", "include"].contains($0.kind) }
        let dependencies = try graph(mtr.map(\.path), checkout: checkout)
        var gaps: [[String: Any]] = []
        for ref in refs {
            try require(digests[ref.path] == ref.sha256, "\(ref.id): SHA256 mismatch for \(ref.path)")
            try validateLocator(ref, text: checkout.text(ref.path))
            guard ["test", "include"].contains(ref.kind) else { continue }
            let known = Set((ref.dependencies + ref.resultRefs).compactMap { byID[$0]?.path })
            let edges = dependencies[ref.path] ?? []
            let discovered = Set(edges.compactMap(\.path) + checkout.companions(ref.path))
            let missing = discovered.subtracting(known).sorted()
            let unresolved = edges.filter { $0.issue != nil }
            if ref.dependenciesReviewed {
                try require(missing.isEmpty && unresolved.isEmpty, "\(ref.id): reviewed dependencies omit discovered files or unresolved includes: \(missing), \(unresolved.map(\.expression))")
                try require(ref.dependencies.allSatisfy { byID[$0]?.dependenciesReviewed == true }, "\(ref.id): reviewed dependency closure contains unreviewed references")
            }
            if !ref.dependenciesReviewed || !missing.isEmpty || !unresolved.isEmpty {
                gaps.append(["reference": ref.id, "unrecorded_files": missing, "unresolved_includes": unresolved.map(\.json), "review_notes": ref.unresolvedDependencies])
            }
        }
        for candidate in upstream.candidates where candidate.repository == repository.id { _ = try checkout.file(candidate.path) }
        try checkout.unchanged()
        return ["repository": repository.id, "revision": repository.revision, "references_checked": refs.count,
                "dependency_files_discovered": dependencies.count, "review_gaps": gaps, "qualification": "unverified"]
    }

    static func scan(_ inventory: DDLCoverage.Inventory, repository: DDLUpstream.Repository, checkout: Checkout, progress: (String) -> Void = { _ in }) throws -> [String: Any] {
        let scopes = Set(inventory.catalog.families.flatMap(\.scanScope)).sorted()
        for scope in scopes { try DDLCoverage.safePath(scope) }
        let explicit = Set(inventory.upstream.candidates.filter { $0.repository == repository.id }.map(\.path))
        let pool = checkout.tracked.filter { path in
            path.hasSuffix(".test") && scopes.contains { path.hasPrefix($0 + "/") }
        }.sorted()
        let pattern = #"(?i)\b(create|alter|drop|rename|truncate)\s+(?:temporary\s+|unique\s+|fulltext\s+|spatial\s+|or\s+replace\s+)*(table|database|schema|index|view|trigger|procedure|function|event|tablespace)\b"#
        var selected = explicit
        progress("Scanning \(pool.count) test files and their literal includes…")
        for path in pool {
            if try checkout.text(path).range(of: pattern, options: .regularExpression) != nil { selected.insert(path) }
        }
        // Include-only wrapper tests are candidates when their reachable static body
        // contains DDL. The graph also keeps non-DDL dependencies and cycles visible.
        let dependencyGraph = try graph(pool + Array(explicit), checkout: checkout)
        var ddlBodies = Set<String>()
        for path in dependencyGraph.keys {
            if try checkout.text(path).range(of: pattern, options: .regularExpression) != nil { ddlBodies.insert(path) }
        }
        var reachable = ddlBodies
        var changed = true
        while changed {
            changed = false
            for (path, edges) in dependencyGraph where !reachable.contains(path) {
                if edges.contains(where: { $0.path.map(reachable.contains) ?? false }) { reachable.insert(path); changed = true }
            }
        }
        selected.formUnion(Set(pool).intersection(reachable))
        progress("Found \(selected.count) candidates; collecting result/options files and SHA256 digests…")
        let sidecars = Dictionary(uniqueKeysWithValues: selected.sorted().map { ($0, checkout.companions($0)) })
        let paths = Set(dependencyGraph.keys).union(sidecars.values.flatMap { $0 }).union(selected)
        let digests = try checkout.hashes(Array(paths))
        let rows: [[String: Any]] = selected.sorted().map { path in
            let records = inventory.upstream.candidates.filter { $0.repository == repository.id && $0.path == path }
            return ["path": path, "sha256": digests[path]!, "selection": explicit.contains(path) ? "catalog_candidate" : "ddl_text_or_literal_include_closure",
                    "family_scope_hints": inventory.catalog.families.filter { family in family.scanScope.contains { path.hasPrefix($0 + "/") } }.map(\.id),
                    "catalog_records": records.map { ["id": $0.id, "family": $0.family, "state": $0.state] },
                    "inventory_change": records.isEmpty ? "addition_for_review" : "existing", "companions": sidecars[path] ?? []]
        }
        let files: [[String: Any]] = paths.sorted().map { path in
            ["path": path, "sha256": digests[path]!, "includes": (dependencyGraph[path] ?? []).map(\.json)]
        }
        try checkout.unchanged()
        return ["schema_version": 1, "repository": repository.id, "revision": repository.revision, "scan_scope": scopes,
                "test_files_examined": pool.count, "candidates": rows, "files": files,
                "limitations": ["Text heuristic, including comments and SQL strings: false positives and negatives require human review.",
                    "Literal include graph only; branches, variables, generated files, suite.pm, configuration/option include semantics, hooks and runtime result selection are not evaluated.",
                    "Include cycles are retained as graph edges; traversal visits each file once.",
                    "Companions are possible results/options, not confirmed runtime selections. Suites outside scan_scope remain unreviewed."],
                "qualification": "unverified"]
    }

    static func run(root: URL, command: String, options: [String], inventory: DDLCoverage.Inventory) throws {
        try require(options.isEmpty || options.count == 2 && options[0] == "--mysql-source", "ddl-catalog \(command) accepts only --mysql-source PATH")
        try require(inventory.upstream.repositories.count == 1, "selecting multiple upstream repositories is not implemented")
        let repository = inventory.upstream.repositories[0]
        let path = options.isEmpty ? repository.localPath : options[1]
        let checkout = try Checkout(root: URL(fileURLWithPath: path, relativeTo: root), revision: repository.revision)
        let validation = try check(inventory.upstream, repository: repository, checkout: checkout)
        let directory = root.appendingPathComponent("artifacts/ddl-catalog-\(command)/" + runID())
        if command == "scan" {
            let report = try scan(inventory, repository: repository, checkout: checkout, progress: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) })
            try writeJSON(report, to: directory.appendingPathComponent("inventory.json"))
            print("DDL scan: \((report["candidates"] as! [[String: Any]]).count) candidates; review inventory.json for additions and unresolved dependencies.")
        } else {
            print("PASS upstream pin/hashes/locators: \(validation["references_checked"]!) references; \((validation["review_gaps"] as! [[String: Any]]).count) references still need dependency review.")
        }
        try writeJSON(validation, to: directory.appendingPathComponent("upstream-check.json"))
        print("Research artifacts: \(directory.path). No replication coverage qualified.")
    }
}
