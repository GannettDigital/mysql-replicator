import XCTest
import Foundation
import ReplicatorConfiguration
@testable import ReplicatorApply
import ReplicatorCapture

final class ConfigurationFileTests: XCTestCase {
    let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func example() throws -> String {
        try String(contentsOf:root.appendingPathComponent("examples/apply.example.yaml"),encoding:.utf8)
            .replacingOccurrences(of:"REPLACE_SOURCE_UUID",with:"00000000-0000-0000-0000-000000000001")
            .replacingOccurrences(of:"REPLACE_SNAPSHOT_GTID_SET",with:"\"\"")
    }
    func testCommentedExampleAndQuotedWildcardDecodeWithExpectedDefaults() throws {
        let text = try example().replacingOccurrences(of:"replicateWildIgnoreTable: []",with:"replicateWildIgnoreTable:\n  - 'scratch.tmp\\_%' # literal underscore\n  - 'other.%'")
        let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
        try config.validate()
        XCTAssertEqual(config.version,2); XCTAssertEqual(config.source.start.executedGTIDs,"")
        XCTAssertEqual(config.replicateWildIgnoreTable,["scratch.tmp\\_%","other.%"])
        XCTAssertEqual(config.ddlPolicy?.triggers,"skip")
        XCTAssertEqual(config.batchPolicy.maximumTransactions,32)
        XCTAssertFalse(config.target.explicitTableLocks); XCTAssertTrue(config.target.requireTLS)
        XCTAssertEqual(config.source.downloadCacheBytes,nil)
    }
    func testYAMLAndYMLExtensionsAndLegacyFilenameRejection() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        for ext in ["yaml","yml"] {
            let file=directory.appendingPathComponent("apply."+ext)
            try example().write(to:file,atomically:true,encoding:.utf8)
            try ConfigurationFile.load(ApplyConfiguration.self,from:file).validate()
        }
        let json=directory.appendingPathComponent("apply.json")
        try Data("{}".utf8).write(to:json)
        XCTAssertThrowsError(try ConfigurationFile.load(ApplyConfiguration.self,from:json)) {
            XCTAssertTrue(String(describing:$0).contains("convert legacy JSON"))
        }
    }
    func testCollationMappingYAMLIsOptInAndValidated() throws {
        let strict = try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(example().utf8))
        XCTAssertTrue(strict.compatibilityPolicy.collations.isEmpty)
        let text = try example()+"\ncompatibility:\n  collations:\n    utf8mb4_0900_ai_ci: utf8mb4_unicode_ci # changes comparisons, not bytes\n"
        let mapped = try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
        try mapped.validate()
        XCTAssertEqual(mapped.compatibilityPolicy.targetID(255),224)
        let invalid = text.replacingOccurrences(of:"utf8mb4_unicode_ci #",with:"latin1_bin #")
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(invalid.utf8)).validate())
    }
    func testMalformedDuplicateAndMultipleDocumentConfigurationsAreRejected() throws {
        for text in [try example()+"\nversion: 2\n", try example()+"\n---\nversion: 2\n",
                     try example().replacingOccurrences(of:"enabled: true",with:"enabled: [broken"),
                     try example().replacingOccurrences(of:"port: 3306",with:"port: not-a-number"),
                     "", "- not-a-config"] {
            XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8)))
        }
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self,from:Data([0xff])))
        XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(repeating:32,count:ConfigurationFile.maximumBytes+1)))
    }
    func testSourceInspectionConfigurationUsesYAMLAndPreservesGTIDStrings() throws {
        let text="""
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
        let config=try ConfigurationFile.decode(CaptureConfiguration.self,from:Data(text.utf8))
        _ = try config.validate()
        XCTAssertEqual(config.sourceUUID,"00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(config.start.executedGTIDs,config.sourceUUID+":1-10")
        XCTAssertTrue(config.nonBlocking == true)
    }
    func testDirectPasswordsPreserveQuotedCharactersAndSurviveSourceResume() throws {
        let secret="literal: #hash $dollar \\backslash 'quote'"
        let literal="'"+secret.replacingOccurrences(of:"'",with:"''")+"'"
        let text=try example()
            .replacingOccurrences(of:"passwordEnvironment: REPLICATOR_SOURCE_PASSWORD",with:"password: "+literal)
            .replacingOccurrences(of:"passwordEnvironment: REPLICATOR_TARGET_PASSWORD",with:"password: ''")
        let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
        try config.validate()
        XCTAssertEqual(config.source.password,secret); XCTAssertNil(config.source.passwordEnvironment)
        XCTAssertEqual(config.target.password,""); XCTAssertNil(config.target.passwordEnvironment)
        let resumed=config.source.resuming(file:"binlog.000123",position:4,executedGTIDs:"")
        XCTAssertEqual(resumed.password,secret); XCTAssertNil(resumed.passwordEnvironment)
        XCTAssertEqual(try PasswordConfiguration.resolve(password:resumed.password,environmentVariable:resumed.passwordEnvironment,endpoint:"source",environment:[:]),secret)
        XCTAssertEqual(try PasswordConfiguration.resolve(password:nil,environmentVariable:"P",endpoint:"target",environment:["P":secret]),secret)
    }
    func testCredentialsRequireOneSelectorAndErrorsDoNotExposeSecrets() throws {
        let secret="secret-not-for-diagnostics"
        for endpoint in ["source","target"] {
            let key="passwordEnvironment: REPLICATOR_"+endpoint.uppercased()+"_PASSWORD"
            for replacement in ["", "passwordEnvironment: ''",key+"\n  password: '"+secret+"'"] {
                let text=try example().replacingOccurrences(of:key,with:replacement)
                let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
                XCTAssertThrowsError(try config.validate()) {
                    let message=String(describing:$0)
                    XCTAssertTrue(message.contains(endpoint))
                    XCTAssertTrue(message.contains("exactly one"))
                    XCTAssertFalse(message.contains(secret))
                }
            }
        }
        XCTAssertThrowsError(try PasswordConfiguration.resolve(password:nil,environmentVariable:"MISSING",endpoint:"source",environment:[:])) {
            XCTAssertTrue(String(describing:$0).contains("environment variable is unset"))
        }
        XCTAssertThrowsError(try PasswordConfiguration.resolve(password:secret,environmentVariable:"P",endpoint:"target",environment:[:])) {
            XCTAssertFalse(String(describing:$0).contains(secret))
        }
    }
    func testParserDiagnosticsDoNotEchoPasswordValues() throws {
        let secret="never-log-this-secret"
        for text in [
            "version: 2\nsource:\n  password: '\(secret)'\n  password: duplicate\n",
            "version: 2\nsource:\n  password: [\(secret)\n",
            try example().replacingOccurrences(of:"port: 3306",with:"port: '\(secret)'")
        ] {
            XCTAssertThrowsError(try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))) {
                let diagnostic=String(describing:$0)
                XCTAssertFalse(diagnostic.contains(secret))
                XCTAssertTrue(diagnostic.contains("line") || diagnostic.contains("source.port"))
            }
        }
    }
    func testReloadIdentityAllowsOnlyLimitsAndIncludesCredentialChanges() throws {
        let original=try example()
        let identity=try ConfigurationFile.reloadIdentity(from:Data(original.utf8))
        let changed=original.replacingOccurrences(of:"source:\n",with:"source:\n  stopAfterGTIDs: '00000000-0000-0000-0000-000000000001:1-20'\n  stopAfterTransactions: 100\n")
        XCTAssertEqual(try ConfigurationFile.reloadIdentity(from:Data(changed.utf8)),identity)
        let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(changed.utf8))
        try config.validate()
        XCTAssertEqual(config.source.stopAfterTransactions,100)
        XCTAssertEqual(config.source.resuming(file:nil,position:nil,executedGTIDs:"").stopAfterGTIDs,config.source.stopAfterGTIDs)
        for change in [original.replacingOccurrences(of:"port: 3306",with:"port: 3307"),
                       original.replacingOccurrences(of:"passwordEnvironment: REPLICATOR_SOURCE_PASSWORD",with:"password: changed-secret"),
                       original+"\nunknownSetting: changed\n"] {
            XCTAssertNotEqual(try ConfigurationFile.reloadIdentity(from:Data(change.utf8)),identity)
        }
        XCTAssertThrowsError(try StopConditions(transactions:nil,gtids:""))
        XCTAssertThrowsError(try StopConditions(transactions:nil,gtids:"invalid"))
        let sid="00000000-0000-0000-0000-000000000001",other="00000000-0000-0000-0000-000000000002"
        let limits=try StopConditions(transactions:nil,gtids:sid+":2,"+other+":3")
        XCTAssertNil(limits.reason(transactions:2,executed:try GTIDSet(sid+":1-20")))
        XCTAssertEqual(limits.reason(transactions:3,executed:try GTIDSet(sid+":1-20,"+other+":1-3")),"gtidsSatisfied")
    }
}
