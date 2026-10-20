import ReplicatorCapture
import ReplicatorConfiguration
import XCTest

@testable import ReplicatorApply

final class ConfigurationOverrideTests: XCTestCase {
    func testHelpDistinguishesSectionsFromValues() throws {
        let help = try ConfigurationOptions.help()
        for section in ["source", "target", "source.start", "batch", "supportBundle"] {
            XCTAssertTrue(help.contains(section + ": (section)"))
            XCTAssertFalse(help.contains("--" + section + " VALUE"))
        }
        for option in ["source.host", "source.start.executedGTIDs", "stateDirectory", "compatibility.collations"] {
            XCTAssertTrue(help.contains("--" + option + " STRING"))
        }
        XCTAssertTrue(help.contains("--SECTION YAML_MAP"))
        XCTAssertTrue(help.contains("--config.version INTEGER"))
    }

    func testTypedOverridesWinAndArraysReplace() throws {
        let options = try ConfigurationOverrides(arguments: [
            "run", "--config", "x.yaml", "--source.port=3307", "--target.preserveSourceGTIDs", "false",
            "--replicateWildDoTable", "['app.%']", "--replicateWildIgnoreTable", "[]", "--statistics.rateWindowSeconds",
            "30",
        ])
        XCTAssertEqual(options.arguments, ["run", "--config", "x.yaml"])
        #if os(Linux)
            let helper = ConfigurationFileTests(name: "fixture", testClosure: { _ in })
        #else
            let helper = ConfigurationFileTests()
        #endif
        let data = try options.applying(to: Data(helper.example().utf8))
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: data)
        try config.validate()
        XCTAssertEqual(config.source.port, 3307)
        XCTAssertFalse(config.target.preserveSourceGTIDs)
        XCTAssertEqual(config.replicateWildDoTable, ["app.%"])
        XCTAssertEqual(config.replicateWildIgnoreTable, [])
        XCTAssertEqual(config.statistics?.rateWindowSeconds, 30)
        let reloaded = try options.applying(
            to: Data(helper.example().replacingOccurrences(of: "port: 3306", with: "port: 4400").utf8))
        XCTAssertEqual(try ConfigurationFile.decode(ApplyConfiguration.self, from: reloaded).source.port, 3307)
    }
    func testStandaloneSourceMapOverride() throws {
        struct Source: Decodable { let port: Int }
        let c = try ConfigurationOverrides(arguments: ["blackhole", "--config", "x.yaml", "--source", "{port: 3307}"])
        let decoded = try ConfigurationFile.decode(Source.self, from: c.applying(to: Data("port: 3306".utf8)))
        XCTAssertEqual(decoded.port, 3307)
    }
    func testNullsAndStandaloneSourceMapping() throws {
        struct Source: Decodable {
            let port: Int
            let caFile: String?
        }
        let options = try ConfigurationOverrides(arguments: [
            "blackhole", "--config", "s.yaml", "--source.port", "3307", "--source.caFile", "null",
        ])
        let source = try ConfigurationFile.decode(
            Source.self, from: options.applying(to: Data("port: 3306\ncaFile: /ca.pem".utf8)))
        XCTAssertEqual(source.port, 3307)
        XCTAssertNil(source.caFile)
        XCTAssertThrowsError(try ConfigurationOverrides(arguments: ["blackhole", "--target.port", "3306"]))
    }
    func testInvalidAndDuplicateOverridesDoNotExposeValues() throws {
        XCTAssertThrowsError(
            try ConfigurationOverrides(arguments: ["run", "--source.port", "3306", "--source.port=3307"]))
        XCTAssertThrowsError(try ConfigurationOverrides(arguments: ["run", "--source", "{}", "--source.port", "3307"]))
        let bad = try ConfigurationOverrides(arguments: ["run", "--source.password", "[ secret: !bad secret"])
        XCTAssertThrowsError(try bad.applying(to: Data("source: {}".utf8))) {
            XCTAssertFalse(String(describing: $0).contains("secret"))
        }
        XCTAssertEqual(try ConfigurationOverrides(arguments: ["--version"]).arguments, ["--version"])
        XCTAssertEqual(
            try ConfigurationOverrides(arguments: ["run", "--source.typo", "1"]).arguments,
            ["run", "--source.typo", "1"])
    }
}
