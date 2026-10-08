import XCTest
@testable import ReplicatorLabCore

final class LabProgressTests: XCTestCase {
    func testEveryPartialWriteRetainsTheLastCompletedProgress() throws {
        let prior=Data("{\"transactionsApplied\":1}\n".utf8)
        let next=Data("{\"transactionsApplied\":2,\"note\":\"café 😀\"}\n".utf8)
        for length in 0..<next.count {
            XCTAssertEqual(try LabProgress.latest(in:prior+next.prefix(length))?["transactionsApplied"] as? Int,1)
        }
        XCTAssertEqual(try LabProgress.latest(in:prior+next)?["transactionsApplied"] as? Int,2)
    }
    func testFirstRecordWaitsForItsTerminatingNewline() throws {
        let first=Data("{\"lifecycle\":\"RUNNING\"}\n".utf8)
        for length in 0..<first.count {
            XCTAssertNil(try LabProgress.latest(in:Data(first.prefix(length))))
        }
        XCTAssertEqual(try LabProgress.latest(in:first)?["lifecycle"] as? String,"RUNNING")
        XCTAssertNil(try LabProgress.latest(in:Data([10])))
    }
    func testMalformedCompletedRecordIsNotSilentlyIgnored() throws {
        let prior=Data("{\"transactionsApplied\":1}\n".utf8)
        XCTAssertThrowsError(try LabProgress.latest(in:prior+Data("{broken}\n".utf8)))
    }
}
