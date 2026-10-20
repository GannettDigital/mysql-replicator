import Foundation
import ReplicatorCapture
import ReplicatorConfiguration
import XCTest

@testable import ReplicatorApply

final class ConfigurationFileTests: XCTestCase {
    func testStructuredConfigurationLocationsAndOverrideLocations() throws {
        struct Config: Decodable {
            struct Source: Decodable { let port: Int }
            let source: Source
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        defer { try? FileManager.default.removeItem(at: file) }
        for yaml in ["source: {port: secret-invalid-port}", "source: {}"] {
            try Data(yaml.utf8).write(to: file)
            XCTAssertThrowsError(try ConfigurationFile.load(Config.self, from: file)) { error in
                guard let failure = error as? ConfigurationError else { return XCTFail("Wrong error type") }
                XCTAssertEqual(failure.configPath, file.path)
                XCTAssertEqual(failure.keyPath, "source.port")
                XCTAssertNil(failure.line)
                XCTAssertFalse(failure.description.contains("secret-invalid-port"))
            }
        }
        try Data("source: {port: 3306}".utf8).write(to: file)
        let overrides = try ConfigurationOverrides(arguments: ["run", "--source.port", "[secret-invalid-port"])
        XCTAssertThrowsError(try overrides.load(Config.self, from: file)) { error in
            guard let failure = error as? ConfigurationError else { return XCTFail("Wrong error type") }
            XCTAssertEqual(failure.configPath, file.path)
            XCTAssertEqual(failure.keyPath, "source.port")
            XCTAssertNil(failure.line)
            XCTAssertNil(failure.column)
            XCTAssertFalse(failure.description.contains("secret-invalid-port"))
        }
    }

    func testBinlogTransportIsOptInAndRejectsConflictingSettings() throws {
        let text = try example()
        let original = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
        XCTAssertEqual(original.target.transport, .sql)
        let binlog = text.replacingOccurrences(of: "transport: sql", with: "transport: binlog")
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(binlog.utf8))
        XCTAssertEqual(config.target.transport, .binlog)
        try config.validate()
        let locked = binlog.replacingOccurrences(of: "explicitTableLocks: false", with: "explicitTableLocks: true")
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(locked.utf8)).validate())
        let invalid = text.replacingOccurrences(of: "transport: sql", with: "transport: invalid")
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(invalid.utf8)))
        let absent = text.split(separator: "\n").filter { !$0.contains("transport: sql") }.joined(separator: "\n")
        XCTAssertEqual(
            try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(absent.utf8)).target.transport, .sql)
    }
    func testSourceGTIDPreservationDefaultsToTrueAndCanBeDisabled() throws {
        let yaml = try example().split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("preserveSourceGTIDs:") }
            .joined(separator: "\n")
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(yaml.utf8))
        XCTAssertTrue(config.target.preserveSourceGTIDs)
        let disabled = yaml.replacingOccurrences(of: "target:", with: "target:\n  preserveSourceGTIDs: false\n#")
        XCTAssertFalse(
            try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(disabled.utf8)).target.preserveSourceGTIDs)
        let invalid = yaml.replacingOccurrences(of: "target:", with: "target:\n  preserveSourceGTIDs: invalid\n#")
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(invalid.utf8)))
    }
    func testConfigurableEventAndTransactionLimitsSurviveResume() throws {
        let original = try example()
        for (event, transaction, valid) in [
            (67_108_864, 268_435_456, true), (1_073_741_824, 1_073_741_824, true), (1_048_576, 2_097_152, true),
            (67_108_864, 1_048_576, false), (1_073_741_825, 1_073_741_825, false),
        ] {
            let yaml = original.replacingOccurrences(
                of: "source:\n",
                with: "source:\n  maximumEventBytes: \(event)\n  maximumTransactionBytes: \(transaction)\n")
            let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(yaml.utf8))
            if valid { try config.validate() } else { XCTAssertThrowsError(try config.validate()) }
            let resumed = config.source.resuming(file: nil, position: nil, executedGTIDs: "")
            XCTAssertEqual(resumed.eventByteLimit, UInt32(event))
            XCTAssertEqual(resumed.transactionLimits.wireBytes, UInt64(transaction))
        }
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    func example() throws -> String {
        try String(contentsOf: root.appendingPathComponent("examples/apply.example.yaml"), encoding: .utf8)
            .replacingOccurrences(of: "REPLACE_SOURCE_UUID", with: "00000000-0000-0000-0000-000000000001")
            .replacingOccurrences(of: "REPLACE_SNAPSHOT_GTID_SET", with: "\"\"")
    }
    func testCommentedExampleAndQuotedWildcardDecodeWithExpectedDefaults() throws {
        let text = try example().replacingOccurrences(
            of: "replicateWildIgnoreTable: []",
            with: "replicateWildIgnoreTable:\n  - 'scratch.tmp\\_%' # literal underscore\n  - 'other.%'")
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
        try config.validate()
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.source.start.executedGTIDs, "")
        XCTAssertEqual(config.replicateWildIgnoreTable, ["scratch.tmp\\_%", "other.%"])
        XCTAssertEqual(config.ddlPolicy?.triggers, "skip")
        XCTAssertEqual(config.batchPolicy.maximumTransactions, 8)
        XCTAssertFalse(config.target.explicitTableLocks)
        XCTAssertTrue(config.target.requireTLS)
        XCTAssertEqual(config.source.downloadCacheBytes, nil)
    }
    func testTargetVerifyCAYAMLAndReloadIdentity() throws {
        let original = try example()
        let text = original.replacingOccurrences(
            of: "serverHostname: REPLACE_TARGET_TLS_HOSTNAME", with: "tlsVerification: verify-ca")
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
        try config.validate()
        XCTAssertEqual(config.target.tlsVerification, .verifyCA)
        XCTAssertNil(config.target.serverHostname)
        XCTAssertEqual(config.target.caFile, "/REPLACE/target-ca.pem")
        XCTAssertEqual(config.source.serverHostname, "REPLACE_SOURCE_TLS_HOSTNAME")
        XCTAssertNotEqual(
            try ConfigurationFile.reloadIdentity(from: Data(original.utf8)),
            try ConfigurationFile.reloadIdentity(from: Data(text.utf8)))
    }

    func testYAMLAndYMLExtensionsAndLegacyFilenameRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["yaml", "yml"] {
            let file = directory.appendingPathComponent("apply." + ext)
            try example().write(to: file, atomically: true, encoding: .utf8)
            try ConfigurationFile.load(ApplyConfiguration.self, from: file).validate()
        }
        let json = directory.appendingPathComponent("apply.json")
        try Data("{}".utf8).write(to: json)
        XCTAssertThrowsError(try ConfigurationFile.load(ApplyConfiguration.self, from: json)) {
            XCTAssertTrue(String(describing: $0).contains("convert legacy JSON"))
        }
    }
    func testCollationMappingYAMLIsOptInAndValidated() throws {
        let strict = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(example().utf8))
        XCTAssertTrue(strict.compatibilityPolicy.collations.isEmpty)
        let text =
            try example()
            + "\ncompatibility:\n  collations:\n    utf8mb4_0900_ai_ci: utf8mb4_unicode_ci # changes comparisons, not bytes\n"
        let mapped = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
        try mapped.validate()
        XCTAssertEqual(mapped.compatibilityPolicy.targetID(255), 224)
        let invalid = text.replacingOccurrences(of: "utf8mb4_unicode_ci #", with: "latin1_bin #")
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(invalid.utf8)).validate())
    }
    func testMalformedDuplicateAndMultipleDocumentConfigurationsAreRejected() throws {
        for text in [
            try example() + "\nversion: 2\n", try example() + "\n---\nversion: 2\n",
            try example().replacingOccurrences(of: "enabled: true", with: "enabled: [broken"),
            try example().replacingOccurrences(of: "port: 3306", with: "port: not-a-number"),
            "", "- not-a-config",
        ] {
            XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8)))
        }
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data([0xff])))
        XCTAssertThrowsError(
            try ConfigurationFile.decode(
                ApplyConfiguration.self, from: Data(repeating: 32, count: ConfigurationFile.maximumBytes + 1)))
    }
    func testSourceInspectionConfigurationUsesYAMLAndPreservesGTIDStrings() throws {
        let text = """
            version: 1
            host: source
            port: 3306
            username: capture
            passwordEnvironment: SOURCE_PASSWORD
            serverHostname: source
            serverID: 9100
            sourceUUID: 00000000-0000-0000-0000-000000000001
            mode: gtid
            start:
              executedGTIDs: '00000000-0000-0000-0000-000000000001:1-10'
            tables:
              - database: poc
                table: items
                columns: [signed, utf8, unsigned]
            nonBlocking: true # stop at EOF
            """
        let config = try ConfigurationFile.decode(CaptureConfiguration.self, from: Data(text.utf8))
        _ = try config.validate()
        XCTAssertEqual(config.sourceUUID, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(config.start.executedGTIDs, config.sourceUUID + ":1-10")
        XCTAssertTrue(config.nonBlocking == true)
    }
    func testDirectPasswordsPreserveQuotedCharactersAndSurviveSourceResume() throws {
        let secret = "literal: #hash $dollar \\backslash 'quote'"
        let literal = "'" + secret.replacingOccurrences(of: "'", with: "''") + "'"
        let text = try example()
            .replacingOccurrences(of: "passwordEnvironment: REPLICATOR_SOURCE_PASSWORD", with: "password: " + literal)
            .replacingOccurrences(of: "passwordEnvironment: REPLICATOR_TARGET_PASSWORD", with: "password: ''")
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
        try config.validate()
        XCTAssertEqual(config.source.password, secret)
        XCTAssertNil(config.source.passwordEnvironment)
        XCTAssertEqual(config.target.password, "")
        XCTAssertNil(config.target.passwordEnvironment)
        let resumed = config.source.resuming(file: "binlog.000123", position: 4, executedGTIDs: "")
        XCTAssertEqual(resumed.password, secret)
        XCTAssertNil(resumed.passwordEnvironment)
        XCTAssertEqual(
            try PasswordConfiguration.resolve(
                password: resumed.password, environmentVariable: resumed.passwordEnvironment, endpoint: "source",
                environment: [:]), secret)
        XCTAssertEqual(
            try PasswordConfiguration.resolve(
                password: nil, environmentVariable: "P", endpoint: "target", environment: ["P": secret]), secret)
    }
    func testCredentialsRequireOneSelectorAndErrorsDoNotExposeSecrets() throws {
        let secret = "secret-not-for-diagnostics"
        for endpoint in ["source", "target"] {
            let key = "passwordEnvironment: REPLICATOR_" + endpoint.uppercased() + "_PASSWORD"
            for replacement in ["", "passwordEnvironment: ''", key + "\n  password: '" + secret + "'"] {
                let text = try example().replacingOccurrences(of: key, with: replacement)
                let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))
                XCTAssertThrowsError(try config.validate()) {
                    let message = String(describing: $0)
                    XCTAssertTrue(message.contains(endpoint))
                    XCTAssertTrue(message.contains("exactly one"))
                    XCTAssertFalse(message.contains(secret))
                }
            }
        }
        XCTAssertThrowsError(
            try PasswordConfiguration.resolve(
                password: nil, environmentVariable: "MISSING", endpoint: "source", environment: [:])
        ) {
            XCTAssertTrue(String(describing: $0).contains("environment variable is unset"))
        }
        XCTAssertThrowsError(
            try PasswordConfiguration.resolve(
                password: secret, environmentVariable: "P", endpoint: "target", environment: [:])
        ) {
            XCTAssertFalse(String(describing: $0).contains(secret))
        }
    }
    func testParserDiagnosticsDoNotEchoPasswordValues() throws {
        let secret = "never-log-this-secret"
        for text in [
            "version: 2\nsource:\n  password: '\(secret)'\n  password: duplicate\n",
            "version: 2\nsource:\n  password: [\(secret)\n",
            try example().replacingOccurrences(of: "port: 3306", with: "port: '\(secret)'"),
        ] {
            XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(text.utf8))) {
                let diagnostic = String(describing: $0)
                XCTAssertFalse(diagnostic.contains(secret))
                XCTAssertTrue(diagnostic.contains("line") || diagnostic.contains("source.port"))
            }
        }
    }
    func testReloadIdentityAllowsOnlyLimitsAndIncludesCredentialChanges() throws {
        let original = try example()
        let identity = try ConfigurationFile.reloadIdentity(from: Data(original.utf8))
        let changed = original.replacingOccurrences(
            of: "source:\n",
            with:
                "source:\n  stopAfterGTIDs: '00000000-0000-0000-0000-000000000001:1-20'\n  stopAfterTransactions: 100\n"
        )
        XCTAssertEqual(try ConfigurationFile.reloadIdentity(from: Data(changed.utf8)), identity)
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(changed.utf8))
        try config.validate()
        XCTAssertEqual(config.source.stopAfterTransactions, 100)
        XCTAssertEqual(
            config.source.resuming(file: nil, position: nil, executedGTIDs: "").stopAfterGTIDs,
            config.source.stopAfterGTIDs)
        for change in [
            original.replacingOccurrences(of: "port: 3306", with: "port: 3307"),
            original.replacingOccurrences(
                of: "passwordEnvironment: REPLICATOR_SOURCE_PASSWORD", with: "password: changed-secret"),
            original + "\nunknownSetting: changed\n",
        ] {
            XCTAssertNotEqual(try ConfigurationFile.reloadIdentity(from: Data(change.utf8)), identity)
        }
        XCTAssertThrowsError(try StopConditions(transactions: nil, gtids: ""))
        XCTAssertThrowsError(try StopConditions(transactions: nil, gtids: "invalid"))
        let sid = "00000000-0000-0000-0000-000000000001"
        let other = "00000000-0000-0000-0000-000000000002"
        let limits = try StopConditions(transactions: nil, gtids: sid + ":2," + other + ":3")
        XCTAssertNil(limits.reason(transactions: 2, executed: try GTIDSet(sid + ":1-20")))
        XCTAssertEqual(
            limits.reason(transactions: 3, executed: try GTIDSet(sid + ":1-20," + other + ":1-3")), "gtidsSatisfied")
    }
}
