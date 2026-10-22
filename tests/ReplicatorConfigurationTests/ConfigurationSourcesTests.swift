import Foundation
import XCTest

@testable import ReplicatorConfiguration

final class ConfigurationSourcesTests: XCTestCase {
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(
            directory, directory.appendingPathComponent("system.yaml"),
            directory.appendingPathComponent(".mysql-replicator.yaml"))
    }
    private func write(_ text: String, _ file: URL) throws { try Data(text.utf8).write(to: file) }
    private func object(_ sources: ConfigurationSources, arguments: [String] = ["run"]) throws -> [String: Any] {
        let value = try ConfigurationFile.decode(
            DiagnosticValue.self, from: sources.read(overrides: ConfigurationOverrides(arguments: arguments))
        ).value
        return try XCTUnwrap(value as? [String: Any])
    }

    func testSystemThenUserMapsArraysNullsAndCLIOverrides() throws {
        try fixture { home, system, user in
            try write(
                """
                target: {host: system, port: 3306, passwordEnvironment: SECRET}
                source: {port: 3306}
                replicateWildIgnoreTable: [old.%, keep.%]
                stateDirectory: /system
                """, system)
            try write(
                """
                target: {port: 3307, passwordEnvironment: null, password: fixture-only}
                replicateWildIgnoreTable: []
                stateDirectory: /user
                """, user)
            let sources = try ConfigurationSources(path: nil, environment: ["HOME": home.path], systemFile: system)
            struct Config: Decodable {
                struct Target: Decodable {
                    let host: String
                    let port: Int
                    let passwordEnvironment: String?
                }
                let target: Target
            }
            let typed = try sources.load(Config.self, overrides: ConfigurationOverrides(arguments: ["run"]))
            XCTAssertEqual(typed.target.host, "system")
            XCTAssertEqual(typed.target.port, 3307)
            XCTAssertNil(typed.target.passwordEnvironment)
            XCTAssertEqual(sources.files, [system, user])
            XCTAssertNil(sources.sourceURL)
            let merged = try object(sources)
            let target = try XCTUnwrap(merged["target"] as? [String: Any])
            XCTAssertEqual(target["host"] as? String, "system")
            XCTAssertEqual(target["port"] as? Int64, 3307)
            XCTAssertTrue(target["passwordEnvironment"] is NSNull)
            XCTAssertEqual(merged["stateDirectory"] as? String, "/user")
            XCTAssertEqual(merged["replicateWildIgnoreTable"] as? [String], [])
            let cli = try object(
                sources, arguments: ["run", "--target.port", "4400", "--replicateWildIgnoreTable", "['cli.%']"])
            XCTAssertEqual((cli["target"] as? [String: Any])?["port"] as? Int64, 4400)
            XCTAssertEqual(cli["replicateWildIgnoreTable"] as? [String], ["cli.%"])
        }
    }

    func testExplicitAndEnvironmentSelectOnlyOneFile() throws {
        try fixture { home, system, user in
            try write("broken: [", system)
            try write("broken: [", user)
            let envFile = home.appendingPathComponent("env.yaml")
            let explicit = home.appendingPathComponent("explicit.yaml")
            try write("stateDirectory: /environment", envFile)
            try write("stateDirectory: /explicit", explicit)
            let env = ["HOME": home.path, ConfigurationSources.environmentKey: envFile.path]
            let selected = try ConfigurationSources(path: nil, environment: env, systemFile: system)
            XCTAssertEqual(selected.files, [envFile])
            XCTAssertEqual(try object(selected)["stateDirectory"] as? String, "/environment")
            let override = try ConfigurationSources(path: explicit.path, environment: env, systemFile: system)
            XCTAssertEqual(try object(override)["stateDirectory"] as? String, "/explicit")
            let missing = home.appendingPathComponent("absent.yaml")
            let unavailable = try ConfigurationSources(path: missing.path, environment: env, systemFile: system)
            XCTAssertThrowsError(try object(unavailable)) {
                XCTAssertEqual(($0 as? ConfigurationError)?.configPath, missing.path)
            }
            let missingEnvironment = try ConfigurationSources(
                path: nil,
                environment: [ConfigurationSources.environmentKey: missing.path], systemFile: system)
            XCTAssertThrowsError(try object(missingEnvironment))
            XCTAssertThrowsError(
                try ConfigurationSources(
                    path: nil, environment: [ConfigurationSources.environmentKey: ""], systemFile: system))
        }
    }

    func testMissingDefaultsAndFixedPathsOnReload() throws {
        try fixture { home, system, user in
            let env = ["HOME": home.path]
            XCTAssertThrowsError(try ConfigurationSources(path: nil, environment: env, systemFile: system))
            try write("source: {stopAfterTransactions: 10}", system)
            let selected = try ConfigurationSources(path: nil, environment: env, systemFile: system)
            XCTAssertEqual(selected.files, [system])
            try write("source: {stopAfterTransactions: 20}", system)
            try write("source: {stopAfterTransactions: 30}", user)
            XCTAssertEqual((try object(selected)["source"] as? [String: Any])?["stopAfterTransactions"] as? Int64, 20)
            let restarted = try ConfigurationSources(path: nil, environment: env, systemFile: system)
            XCTAssertEqual((try object(restarted)["source"] as? [String: Any])?["stopAfterTransactions"] as? Int64, 30)
            try FileManager.default.removeItem(at: system)
            XCTAssertThrowsError(try object(selected))
            XCTAssertThrowsError(try object(restarted))
            XCTAssertEqual(try ConfigurationSources(path: nil, environment: env, systemFile: system).files, [user])
        }
    }

    func testMalformedDefaultsKeepFileLocationAndDoNotExposeSecrets() throws {
        try fixture { home, system, user in
            try write("source: {password: [private-value}", system)
            try write("stateDirectory: /user", user)
            let selected = try ConfigurationSources(path: nil, environment: ["HOME": home.path], systemFile: system)
            XCTAssertThrowsError(try object(selected)) {
                XCTAssertEqual(($0 as? ConfigurationError)?.configPath, system.path)
                XCTAssertNotNil(($0 as? ConfigurationError)?.line)
                XCTAssertFalse(String(describing: $0).contains("private-value"))
            }
            try write("stateDirectory: /system", system)
            try write("source: {port: 3306, port: 3307}", user)
            XCTAssertThrowsError(try object(selected)) {
                XCTAssertEqual(($0 as? ConfigurationError)?.configPath, user.path)
            }
            try write("[invalid, root]", user)
            XCTAssertThrowsError(try object(selected))
        }
    }

    func testMergedSizeLimitAndScalarReplacement() throws {
        try fixture { home, system, user in
            try write("source: {port: 3306}\nextra: " + String(repeating: "a", count: 600_000), system)
            try write("source: null\nother: " + String(repeating: "b", count: 600_000), user)
            let selected = try ConfigurationSources(path: nil, environment: ["HOME": home.path], systemFile: system)
            XCTAssertThrowsError(try object(selected))
            try write("source: null", user)
            XCTAssertTrue(try object(selected)["source"] is NSNull)
        }
    }
}
