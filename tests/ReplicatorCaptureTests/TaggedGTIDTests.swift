import Foundation
import ReplicatorCodec
import XCTest

@testable import ReplicatorCapture

final class TaggedGTIDTests: XCTestCase {
    let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    func testIdentityAndIntervalsRemainSeparateAcrossTags() throws {
        var set = try GTIDSet(sid + ":1-9:Blue:1-2:Green:1")
        XCTAssertEqual(set.canonical, sid + ":1-9:blue:1-2:green:1")
        XCTAssertFalse(set.contains(try SourceGTID(parsing: sid + ":green:2")))
        XCTAssertTrue(set.contains(try SourceGTID(parsing: sid + ":BLUE:2")))
        try set.include(SourceGTID(parsing: sid + ":green:2"))
        try set.include(SourceGTID(parsing: sid + ":blue:4"))
        try set.include(SourceGTID(parsing: sid + ":blue:3"))
        XCTAssertEqual(set.canonical, sid + ":1-9:blue:1-4:green:1-2")
        XCTAssertFalse(try set.covers(GTIDSet(sid + ":red:1")))
        XCTAssertFalse(try GTIDSet(sid + ":1-100").covers(set))
        XCTAssertEqual(try set.union(GTIDSet(sid + ":green:3:red:1")).canonical, sid + ":1-9:blue:1-4:green:1-3:red:1")
        XCTAssertEqual(try SourceGTID(parsing: sid.uppercased() + ":BLUE:0001").canonical, sid + ":blue:1")
    }
    func testBinarySetAndDumpRequestRoundTrip() throws {
        for text in ["", sid + ":1-3", sid + ":blue:1", sid + ":1-9:blue:1-2:green:1"] {
            let set = try GTIDSet(text)
            let wire = Data(set.encoded().readableBytesView)
            XCTAssertEqual(try GTIDSet(encoded: wire), set)
            XCTAssertEqual(wire[7], text.contains("blue") ? 1 : 0)
            let request = try DumpStart.gtid(set).packet(serverID: 9010, nonBlocking: false)
            XCTAssertEqual(Data(request.payload.readableBytesView).suffix(wire.count), wire)
            for n in 0..<wire.count { XCTAssertThrowsError(try GTIDSet(encoded: wire.prefix(n))) }
            XCTAssertThrowsError(try GTIDSet(encoded: wire + Data([0])))
        }
        let set = try GTIDSet(sid + ":blue:1")
        let wire = Data(set.encoded().readableBytesView)
        XCTAssertEqual(Array(wire.prefix(8)), [1, 1, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(Array(wire[24..<29]), [8, 98, 108, 117, 101])  // native length encoding
        var unknown = wire
        unknown[7] = 2
        XCTAssertThrowsError(try GTIDSet(encoded: unknown))
        var huge = wire
        huge[24] = 66
        XCTAssertThrowsError(try GTIDSet(encoded: huge))
    }
    func testTagsAndIdentityLimitsRejectWithoutChangingState() throws {
        var set = try GTIDSet(sid + ":1")
        var before = set
        for tag in ["", "1bad", "bad-tag", "a:b", "é", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try set.include(sid: sid, sequence: "1", tag: tag))
            XCTAssertEqual(set, before)
            XCTAssertThrowsError(try SourceGTID(parsing: sid + ":" + tag + ":1"))
        }
        for n in 0..<63 { try set.include(sid: sid, sequence: "1", tag: "tag_\(n)") }
        before = set
        XCTAssertThrowsError(try set.include(sid: sid, sequence: "1", tag: "one_more"))
        XCTAssertEqual(set, before)
        try set.include(sid: sid, sequence: "2", tag: "tag_0")
        XCTAssertTrue(set.contains(sid: sid, sequence: "2", tag: "tag_0"))
    }
}
