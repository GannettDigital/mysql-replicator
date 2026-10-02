import XCTest
@testable import ReplicatorCodec

final class StageTimingsTests: XCTestCase {
    func testNativeChildrenAreSubtractedOnceAndZeroCountsIgnored() {
        var now: UInt64 = 0
        let timings = StageTimings(clock:{ now })
        timings.measure("outer") {
            now = 10
            timings.measure("ffi") {
                timings.recordNative("rust",count:1,failures:1,nanoseconds:30)
                timings.recordNative("unused",count:0,failures:0,nanoseconds:0)
                now = 60
            }
            now = 100
        }
        let s=timings.snapshot
        XCTAssertEqual(s["outer"]!.selfSeconds,50e-9,accuracy:1e-15)
        XCTAssertEqual(s["ffi"]!.selfSeconds,20e-9,accuracy:1e-15)
        XCTAssertEqual(s["rust"]!.selfSeconds,30e-9,accuracy:1e-15)
        XCTAssertEqual(s["rust"]!.failures,1)
        XCTAssertNil(s["unused"])
    }

    func testExclusiveTimeSubtractsNestedWorkAndUnwindsOnFailure() throws {
        enum Failure: Error { case injected }
        var now: UInt64 = 0
        let timings = StageTimings(clock:{ now })
        XCTAssertThrowsError(try timings.measure("outer") {
            now = 10
            timings.measure("child") {
                now = 20
                timings.measure("grandchild") { now = 50 }
                now = 60
            }
            now = 80
            try timings.measure("child") { now = 100; throw Failure.injected }
        }) { XCTAssertTrue($0 is Failure) }
        let s=timings.snapshot
        XCTAssertEqual(s["outer"]!.seconds,100e-9,accuracy:1e-15)
        XCTAssertEqual(s["outer"]!.selfSeconds,30e-9,accuracy:1e-15)
        XCTAssertEqual(s["child"]!.seconds,70e-9,accuracy:1e-15)
        XCTAssertEqual(s["child"]!.selfSeconds,40e-9,accuracy:1e-15)
        XCTAssertEqual(s["grandchild"]!.selfSeconds,30e-9,accuracy:1e-15)
        XCTAssertEqual(s["child"]!.count,2)
        XCTAssertEqual(s["child"]!.failures,1)
        XCTAssertEqual(s["outer"]!.failures,1)
        timings.measure("after") { now = 150 }
        XCTAssertEqual(timings.snapshot["after"]!.selfSeconds,50e-9,accuracy:1e-15)
        XCTAssertNoThrow(try JSONEncoder().encode(timings.snapshot))
    }
}
