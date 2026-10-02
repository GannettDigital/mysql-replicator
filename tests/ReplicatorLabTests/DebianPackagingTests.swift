import XCTest
@testable import ReplicatorLabCore

final class DebianPackagingTests: XCTestCase {
    func testDefaultPackagingOptions() throws {
        let options = try DebianPackagingOptions(arguments: [])
        XCTAssertEqual(options.version, "0.1.0")
        XCTAssertEqual(options.outputDirectory, "artifacts/deb")
        XCTAssertFalse(options.skipBuild)
        XCTAssertFalse(options.skipVerification)
    }

    func testCustomPackagingOptions() throws {
        let options = try DebianPackagingOptions(arguments: [
            "--version", "1.2.3-1",
            "--output", "dist/deb",
            "--skip-build",
            "--skip-verification"
        ])
        XCTAssertEqual(options.version, "1.2.3-1")
        XCTAssertEqual(options.outputDirectory, "dist/deb")
        XCTAssertTrue(options.skipBuild)
        XCTAssertTrue(options.skipVerification)
    }

    func testInvalidVersionStringsAreRejected() throws {
        for invalid in ["", "abc", "1.0.0/evil", "1.0.0\n", "1.0.0\r", "1.0.0\r\n",
                        "1.0.0\u{0085}", "1.0.0\u{2028}", "1.0.0\u{2029}", "1.0.0\n2",
                        "\n1.0.0", "1.0.0 ", "1.0.0; rm -rf", "1.0.0--beta"] {
            XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--version", invalid]),
                                 "accepted invalid version: \(String(reflecting: invalid))")
        }
    }

    func testValidDebianVersionsAreAccepted() throws {
        for valid in ["0.1.0", "1.0.0", "2.1.0-1", "0.9.1+git20261001", "1.0~rc1"] {
            let opt = try DebianPackagingOptions(arguments: ["--version", valid])
            XCTAssertEqual(opt.version, valid)
        }
    }

    func testMissingArgumentValuesAreRejected() throws {
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--version"]))
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--output"]))
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--unknown-flag"]))
    }
}
