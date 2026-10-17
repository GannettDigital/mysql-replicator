import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

final class TaggedGTIDStateTests:XCTestCase {
    func testTagsSurviveCheckpointReopenAndRejectOnlyExactDuplicates() throws {
        #if os(Linux)
        let helper=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helper=ApplyTests()
        #endif
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let config=try helper.config(parent.appendingPathComponent("state").path)
        let samples=try helper.groups()
        func group(_ index:Int,_ tag:String?) -> CompleteTransaction {
            let base=samples[index]
            return CompleteTransaction(start:base.start,end:base.end,gtid:.init(sid:helper.sid,sequence:"11",flags:0,tag:tag),anonymous:false,outcome:base.outcome,events:base.events)
        }
        let blue=group(0,"blue"),green=group(1,"green"),plain=group(2,nil)
        var store:StateStore?=try StateStore(configuration:config)
        try store!.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
        try store!.running()
        for g in [blue,green,plain] {
            try store!.begin(g);try store!.complete(g,rowCount:0,filtered:true)
        }
        let expected=helper.sid+":1-11:blue:11:green:11"
        XCTAssertEqual(store!.gtids,expected)
        XCTAssertEqual(try store!.durableAppliedGTIDs(),expected)
        XCTAssertThrowsError(try store!.begin(blue))
        try store!.stopped();store=nil
        let db=URL(fileURLWithPath:config.stateDirectory).appendingPathComponent("state.sqlite")
        XCTAssertEqual(try helper.sqlite(db,"PRAGMA user_version"),[["12"]])
        store=try StateStore(configuration:config,initialize:false)
        XCTAssertEqual(store!.gtids,expected)
        XCTAssertEqual(store!.transactions,3)
        XCTAssertThrowsError(try store!.begin(green))
        store=nil
    }
    func testFormatTenStateUpgradesWithoutChangingExistingProgress() throws {
        #if os(Linux)
        let helper=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helper=ApplyTests()
        #endif
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let config=try helper.config(parent.appendingPathComponent("state").path)
        do {let store=try StateStore(configuration:config);try store.bindTargetIdentity("11111111-1111-1111-1111-111111111111");try store.running();try store.stopped()}
        let db=URL(fileURLWithPath:config.stateDirectory).appendingPathComponent("state.sqlite")
        try writeGTIDTestState(db,"PRAGMA user_version=10")
        do {let store=try StateStore(configuration:config,initialize:false);XCTAssertEqual(store.gtids,helper.sid+":1-10")}
        XCTAssertEqual(try helper.sqlite(db,"PRAGMA user_version"),[["12"]])
    }
}
