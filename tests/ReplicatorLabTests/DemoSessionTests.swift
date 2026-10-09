import XCTest
@testable import ReplicatorLabCore

final class DemoSessionTests: XCTestCase {
    func testReverseSessionIdentityCannotSelectArbitraryResources() throws {
        let id="20261001T010000Z-abcdef12", digest="sha256:"+String(repeating:"a",count:64)
        try LabDemo.Manifest(profile:.reverse,identifier:id,image:digest,ready:true).validate()
        XCTAssertThrowsError(try LabDemo.Manifest(profile:.reverse,identifier:"../../production",image:digest,ready:true).validate())
        XCTAssertThrowsError(try LabDemo.Manifest(profile:.reverse,identifier:id,image:"mysql-replicator-packaging:reverse",ready:true).validate())
        XCTAssertThrowsError(try LabDemo.Manifest(profile:.reverse,identifier:id,image:"mysql-replicator-packaging:reverse",ready:false).validate())
    }
    func testSessionIdentityCannotSelectArbitraryDockerResources() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        try ForwardBenchmarkFixture.Manifest(version: 2, identifier: "20261001T010000Z-abcdef12", image: digest, ready: false).validate()
        for id in ["20261001T010000Z-abcdef12\n", "../../production", "production", "20261001T010000Z-abcdef12\n--all", "20261001T010000Z-ABCDEF12"] {
            XCTAssertThrowsError(try ForwardBenchmarkFixture.Manifest(version: 1, identifier: id, image: digest, ready: true).validate())
        }
        XCTAssertThrowsError(try ForwardBenchmarkFixture.Manifest(version: 3, identifier: "20261001T010000Z-abcdef12", image: digest, ready: true).validate())
        XCTAssertThrowsError(try ForwardBenchmarkFixture.Manifest(version: 1, identifier: "20261001T010000Z-abcdef12", image: "mutable:tag", ready: true).validate())
    }
    func testManifestKeepsCoveragePinnedAndAcceptsOlderSharedSessions() throws {
        let image="sha256:"+String(repeating:"a",count:64)
        let manifest=LabDemo.Manifest(profile:.forward,identifier:"20261001T010000Z-abcdef12",image:image,ready:true,codeCoverage:true)
        let data=try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(LabDemo.Manifest.self,from:data).codeCoverage,true)
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        old.removeValue(forKey:"codeCoverage")
        let restored=try JSONDecoder().decode(LabDemo.Manifest.self,from:JSONSerialization.data(withJSONObject:old))
        try restored.validate(); XCTAssertNil(restored.codeCoverage)
        XCTAssertThrowsError(try LabDemo.Manifest(profile:.forward,identifier:manifest.identifier+"\n",image:image,ready:true).validate())
    }

}
