import XCTest
@testable import ReplicatorLabCore

final class DemoSessionTests: XCTestCase {
    func testSessionIdentityCannotSelectArbitraryDockerResources() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        try DemoSession.Manifest(version: 2, identifier: "20261001T010000Z-abcdef12", image: digest, ready: false).validate()
        for id in ["20261001T010000Z-abcdef12\n", "../../production", "production", "20261001T010000Z-abcdef12\n--all", "20261001T010000Z-ABCDEF12"] {
            XCTAssertThrowsError(try DemoSession.Manifest(version: 1, identifier: id, image: digest, ready: true).validate())
        }
        XCTAssertThrowsError(try DemoSession.Manifest(version: 3, identifier: "20261001T010000Z-abcdef12", image: digest, ready: true).validate())
        XCTAssertThrowsError(try DemoSession.Manifest(version: 1, identifier: "20261001T010000Z-abcdef12", image: "mutable:tag", ready: true).validate())
    }
}
