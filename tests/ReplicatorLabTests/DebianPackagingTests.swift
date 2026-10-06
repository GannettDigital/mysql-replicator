import XCTest
import ReplicatorConfiguration
@testable import ReplicatorLabCore

final class DebianPackagingTests: XCTestCase {
    func testDefaultPackagingOptions() throws {
        let options = try DebianPackagingOptions(arguments: [])
        XCTAssertEqual(options.version, ReleaseVersion.debian)
        XCTAssertEqual(options.outputDirectory, "artifacts/deb")
        XCTAssertFalse(options.skipBuild)
        XCTAssertFalse(options.skipVerification)
    }

    func testCustomPackagingOptions() throws {
        let options = try DebianPackagingOptions(arguments: [
            "--output", "dist/deb",
            "--skip-build",
            "--skip-verification"
        ])
        XCTAssertEqual(options.version, ReleaseVersion.debian)
        XCTAssertEqual(options.outputDirectory, "dist/deb")
        XCTAssertTrue(options.skipBuild)
        XCTAssertTrue(options.skipVerification)
    }

    func testVersionOverridesAreRejectedBeforeBuilding() throws {
        for arguments in [["--version"], ["--version", ReleaseVersion.debian], ["--version", "1.2.3-1"]] {
            XCTAssertThrowsError(try DebianPackagingOptions(arguments: arguments)) {
                XCTAssertTrue(String(describing: $0).contains("version comes from VERSION"))
            }
        }
    }

    func testMissingArgumentValuesAreRejected() throws {
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--version"]))
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--output"]))
        XCTAssertThrowsError(try DebianPackagingOptions(arguments: ["--unknown-flag"]))
    }
}
