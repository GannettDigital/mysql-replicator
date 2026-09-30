import Foundation
import XCTest
@testable import ReplicatorLabCore

final class DDLUpstreamInspectionTests: XCTestCase {
    private func fixture(_ body: (URL, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddl-upstream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["mysql-test/t/lifecycle.test": "--source include/a.inc\nCREATE TABLE t (id INT);\n",
                     "mysql-test/include/a.inc": "source include/b.inc;\n",
                     "mysql-test/include/b.inc": "--source include/a.inc\n",
                     "mysql-test/t/wrapper.test": "--source include/ddl.inc\n",
                     "mysql-test/include/ddl.inc": "ALTER TABLE t ADD x INT;\n",
                     "mysql-test/t/no-ddl.test": "SELECT 1;\n",
                     "mysql-test/t/missing.test": "--source include/absent.inc\n",
                     "mysql-test/t/dynamic.test": "--source $generated_file\n",
                     "mysql-test/r/lifecycle.result": "CREATE TABLE t (id INT);\n",
                     "mysql-test/r/wrapper.result": "ALTER TABLE t ADD x INT;\n",
                     "mysql-test/t/lifecycle.cnf": "[mysqld.1]\n",
                     "mysql-test/t/lifecycle.combinations": "[variant]\n",
                     "mysql-test/t/suite.opt": "--sql-mode=NO_ENGINE_SUBSTITUTION\n",
                     "mysql-test/include/default_my.cnf": "[mysqld.1]\n",
                     "mysql-test/t/lifecycle-master.opt": "--default-storage-engine=MyISAM\n"]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let runner = ProcessRunner(root: root)
        _ = try runner.run(["git", "init", "--quiet"])
        _ = try runner.run(["git", "add", "."])
        _ = try runner.run(["git", "-c", "user.name=DDL test", "-c", "user.email=ddl@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
        try body(root, runner.run(["git", "rev-parse", "HEAD"]).text)
    }

    private func reference(hash: String, dependencies: [String] = [], reviewed: Bool = false, end: Int = 2, anchor: String = "CREATE TABLE") -> DDLUpstream.Reference {
        .init(id: "test", repository: "mysql", path: "mysql-test/t/lifecycle.test", kind: "test", sha256: hash,
              locator: .init(anchor: anchor, startLine: 1, endLine: end), dependencies: dependencies, resultRefs: [],
              unresolvedDependencies: reviewed ? [] : ["transitive setup unreviewed"], dependenciesReviewed: reviewed)
    }

    func testLiteralLookupPrefersIncludingDirectoryAndReportsDynamicMissingPaths() {
        let tracked: Set<String> = ["mysql-test/t/local.inc", "mysql-test/include/a.inc", "mysql-test/t/include/a.inc"]
        let edges = DDLUpstreamInspection.includes("""
        # --source ignored.inc
        --source local.inc
        source include/a.inc;
        --source include/$engine.inc
        --source absent.inc
        --source ../outside.inc
        """, path: "mysql-test/t/test.test", tracked: tracked)
        XCTAssertEqual(edges.map(\.line), [2, 3, 4, 5, 6])
        XCTAssertEqual(edges[0].path, "mysql-test/t/local.inc")
        XCTAssertEqual(edges[1].path, "mysql-test/t/include/a.inc")
        XCTAssertEqual(edges[2].issue, "dynamic_or_unsupported_include")
        XCTAssertEqual(edges[3].issue, "missing_literal_include")
        XCTAssertEqual(edges[4].issue, "dynamic_or_unsupported_include")
    }

    func testLocatorUsesDeclaredRangeAndRejectsMissingAmbiguousAndOutOfRangeAnchors() throws {
        let ref = reference(hash: "unused", end: 2)
        try DDLUpstreamInspection.validateLocator(ref, text: "CREATE TABLE a;\nresult\nCREATE TABLE b;")
        for text in ["CREATE TABLE a;\nCREATE TABLE b;", "unrelated\ntext", "short"] {
            XCTAssertThrowsError(try DDLUpstreamInspection.validateLocator(ref, text: text))
        }
    }

    func testPinnedCheckoutHashesCycleTraversalAndCompanionDiscovery() throws {
        try fixture { root, revision in
            let checkout = try DDLUpstreamInspection.Checkout(root: root, revision: revision)
            let graph = try DDLUpstreamInspection.graph(["mysql-test/t/lifecycle.test"], checkout: checkout)
            XCTAssertEqual(graph.count, 3)
            XCTAssertEqual(graph["mysql-test/include/b.inc"]?.first?.path, "mysql-test/include/a.inc")
            XCTAssertEqual(DDLUpstreamInspection.companions("mysql-test/t/lifecycle.test", tracked: checkout.tracked),
                           ["mysql-test/include/default_my.cnf", "mysql-test/r/lifecycle.result", "mysql-test/t/lifecycle-master.opt", "mysql-test/t/lifecycle.cnf", "mysql-test/t/lifecycle.combinations", "mysql-test/t/suite.opt"])
            let hash = try XCTUnwrap(checkout.hashes(["mysql-test/t/lifecycle.test"])["mysql-test/t/lifecycle.test"])
            XCTAssertEqual(hash, "5b9e22c80a36127df211782a15616209c60dcb8172473b36882a74cd5c4f1f3c")
            let repository = DDLUpstream.Repository(id: "mysql", url: "https://example.invalid/mysql", revision: revision, localPath: ".upstream/mysql")
            let upstream = DDLUpstream(schemaVersion: 1, repositories: [repository], references: [reference(hash: hash)], candidates: [])
            let result = try DDLUpstreamInspection.check(upstream, repository: repository, checkout: checkout)
            XCTAssertEqual((result["review_gaps"] as? [[String: Any]])?.count, 1)
            for ref in [reference(hash: String(repeating: "0", count: 64)), reference(hash: hash, reviewed: true)] {
                XCTAssertThrowsError(try DDLUpstreamInspection.check(.init(schemaVersion: 1, repositories: [repository], references: [ref], candidates: []), repository: repository, checkout: checkout))
            }
        }
    }

    func testWrongRevisionDirtyCheckoutAndMissingCheckoutFail() throws {
        try fixture { root, revision in
            XCTAssertThrowsError(try DDLUpstreamInspection.Checkout(root: root, revision: String(repeating: "0", count: 40)))
            try Data("changed".utf8).write(to: root.appendingPathComponent("mysql-test/include/a.inc"))
            XCTAssertThrowsError(try DDLUpstreamInspection.Checkout(root: root, revision: revision))
            XCTAssertThrowsError(try DDLUpstreamInspection.Checkout(root: root.appendingPathComponent("absent"), revision: revision))
        }
    }

    func testUnsafeMissingAndSymlinkPathsFailBeforeReading() throws {
        try fixture { root, revision in
            let checkout = try DDLUpstreamInspection.Checkout(root: root, revision: revision)
            let edges = DDLUpstreamInspection.includes("--source absent.inc", path: "mysql-test/t/lifecycle.test", tracked: checkout.tracked)
            XCTAssertEqual(edges.first?.issue, "missing_literal_include")
            XCTAssertThrowsError(try checkout.file("../outside"))
            XCTAssertThrowsError(try checkout.file("mysql-test/include/absent.inc"))
            // A tracked path replaced by a symlink is rejected before reading it.
            let target = root.appendingPathComponent("mysql-test/include/a.inc")
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("mysql-test/include/b.inc"))
            XCTAssertThrowsError(try checkout.file("mysql-test/include/a.inc"))
        }
    }

    func testScannerFindsIncludeWrappersSidecarsAndGapsWithoutMutatingCatalog() throws {
        try fixture { root, revision in
            let checkout = try DDLUpstreamInspection.Checkout(root: root, revision: revision)
            let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DDLCoverage")
            let original = try DDLCoverage.load(directory: catalog)
            let repository = DDLUpstream.Repository(id: "mysql", url: "https://example.invalid/mysql", revision: revision, localPath: "fixture")
            let inventory = DDLCoverage.Inventory(catalog: original.catalog, profiles: original.profiles,
                upstream: .init(schemaVersion: 1, repositories: [repository], references: [], candidates: []))
            let first = try DDLUpstreamInspection.scan(inventory, repository: repository, checkout: checkout)
            let second = try DDLUpstreamInspection.scan(inventory, repository: repository, checkout: checkout)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: second, options: [.sortedKeys]))
            let candidates = try XCTUnwrap(first["candidates"] as? [[String: Any]])
            XCTAssertEqual(candidates.compactMap { $0["path"] as? String }, ["mysql-test/t/lifecycle.test", "mysql-test/t/wrapper.test"])
            XCTAssertTrue(candidates.allSatisfy { $0["inventory_change"] as? String == "addition_for_review" })
            let files = try XCTUnwrap(first["files"] as? [[String: Any]])
            let issues = files.flatMap { ($0["includes"] as? [[String: Any]]) ?? [] }.compactMap { $0["issue"] as? String }
            XCTAssertTrue(issues.contains("missing_literal_include"))
            XCTAssertTrue(issues.contains("dynamic_or_unsupported_include"))
            XCTAssertTrue(files.contains { $0["path"] as? String == "mysql-test/r/wrapper.result" })
            XCTAssertEqual(first["qualification"] as? String, "unverified")
            XCTAssertTrue(try checkout.runner.run(["git", "status", "--porcelain"]).stdout.isEmpty)
        }
    }

    func testMissingLiteralIncludeFailsReviewedDependencyClaim() throws {
        try fixture { root, revision in
            let checkout = try DDLUpstreamInspection.Checkout(root: root, revision: revision)
            let path = "mysql-test/t/missing.test"
            let digest = try XCTUnwrap(checkout.hashes([path])[path])
            let ref = DDLUpstream.Reference(id: "missing", repository: "mysql", path: path, kind: "test", sha256: digest,
                locator: .init(anchor: "--source", startLine: 1, endLine: 1), dependencies: [], resultRefs: [], unresolvedDependencies: [], dependenciesReviewed: true)
            let repository = DDLUpstream.Repository(id: "mysql", url: "https://example.invalid/mysql", revision: revision, localPath: "fixture")
            XCTAssertThrowsError(try DDLUpstreamInspection.check(.init(schemaVersion: 1, repositories: [repository], references: [ref], candidates: []), repository: repository, checkout: checkout)) { error in
                XCTAssertTrue(String(describing: error).contains("reviewed dependencies omit"))
            }
        }
    }
}
