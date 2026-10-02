import XCTest
@testable import ReplicatorCapture

final class GTIDUpdateTests: XCTestCase {
    let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    func testNumericUpdatesMatchTextNormalizationInArbitraryOrder() throws {
        var set = try GTIDSet("")
        // Permutation exercises insertion, extension on either end, bridging,
        // and duplicates; compare both textual and binary wire representations.
        for n in (0..<257).map({ ($0*73)%257+1 }) + [1,128,257] {
            let reference = try GTIDSet(set.isEmpty ? sid+":\(n)" : set.canonical+":\(n)")
            try set.include(sid:sid.uppercased(),sequence:String(n))
            XCTAssertEqual(set,reference)
            XCTAssertEqual(set.canonical,reference.canonical)
            XCTAssertEqual(set.encoded(),reference.encoded())
        }
        XCTAssertEqual(set.canonical,sid+":1-257")
        try set.include(sid:"00000000-0000-0000-0000-000000000001",sequence:"0001")
        XCTAssertTrue(set.canonical.hasPrefix("00000000-0000-0000-0000-000000000001:1,"))
    }
    func testRejectedUpdatesAreAtomicAndNumericBoundsDoNotOverflow() throws {
        var set = try GTIDSet(sid+":1:4-5")
        let original = set
        for value in ["", "0", "-1", "+1", "1:7", "1-7", "1,2", " 1", "1 ", String(Int64.max), String(UInt64.max)] {
            XCTAssertThrowsError(try set.include(sid:sid,sequence:value),value)
            XCTAssertEqual(set,original)
        }
        XCTAssertThrowsError(try set.include(sid:"bad",sequence:"6"))
        XCTAssertEqual(set,original)
        try set.include(sid:sid,sequence:String(Int64.max-1))
        try set.include(sid:sid,sequence:String(Int64.max-2))
        XCTAssertTrue(set.canonical.hasSuffix("\(Int64.max-2)-\(Int64.max-1)"))
    }
    func testIntervalAndSIDLimitsPermitMergesButRejectGrowth() throws {
        var set = try GTIDSet(sid+":"+(0..<4096).map { String($0*2+1) }.joined(separator:":"))
        let original = set
        XCTAssertThrowsError(try set.include(sid:sid,sequence:"9000"))
        XCTAssertEqual(set,original)
        try set.include(sid:sid,sequence:"1") // duplicate at capacity
        try set.include(sid:sid,sequence:"2") // bridge at capacity
        XCTAssertTrue(set.canonical.hasPrefix(sid+":1-3:5"))
        try set.include(sid:sid,sequence:"9000") // merge made room
        func uuid(_ n: Int) -> String { String(format:"00000000-0000-0000-0000-%012d",n) }
        set = try GTIDSet((0..<64).map { uuid($0)+":1" }.joined(separator:","))
        let full = set
        XCTAssertThrowsError(try set.include(sid:uuid(64),sequence:"1"))
        XCTAssertEqual(set,full)
        try set.include(sid:uuid(0),sequence:"2")
    }
    func testCanonicalByteLimitStillAppliesWithoutSerialization() throws {
        let limit = 1024*1024, intervalCount = (limit-(16*37-1))/17
        var entries: [String] = [], remaining = intervalCount
        for i in 0..<16 {
            let count = min(4096,remaining)
            let ranges = (0..<count).map { String(1_000_000_000_000_000 + $0*2) }
            entries.append(String(format:"00000000-0000-0000-0000-%012d",i)+":"+ranges.joined(separator:":"))
            remaining -= count
        }
        var set = try GTIDSet(entries.joined(separator:",")), original = set
        XCTAssertLessThanOrEqual(set.canonical.utf8.count,limit)
        XCTAssertGreaterThan(set.canonical.utf8.count+17,limit)
        XCTAssertThrowsError(try set.include(sid:"00000000-0000-0000-0000-000000000015",sequence:"2000000000000000"))
        XCTAssertEqual(set,original)
        try set.include(sid:"00000000-0000-0000-0000-000000000015",sequence:"1000000000000001")
        original = try GTIDSet(set.canonical)
        XCTAssertEqual(set,original)
    }
}
