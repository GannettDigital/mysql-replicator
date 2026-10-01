import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

final class SkipTests: XCTestCase {
    var fixture: ResumeTests {
        #if os(Linux)
        return ResumeTests(name:"fixtures",testClosure:{_ in})
        #else
        return ResumeTests()
        #endif
    }
    func directory() throws -> URL {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        addTeardownBlock { try FileManager.default.removeItem(at:parent) }
        return parent.appendingPathComponent("state")
    }
    func pending(_ group: CompleteTransaction, _ store: StateStore) throws {
        for event in group.events { try store.append(LiveRecord(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
        try store.begin(group); try store.block("unsupported event before target writes")
    }
    func dump(_ path: URL) throws -> [[String]] {
        let h=fixture.helper, db=path.appendingPathComponent("state.sqlite")
        return try ["state","groups","snapshots","row_intents","ddl_intents","schemas"].flatMap { try h.sqlite(db,"SELECT * FROM " + $0) }
    }
    func testSkipPreservesAppliedDeltasSchemasCountersAndRelayThenResumesBothProtocols() throws {
        let f=fixture, h=f.helper, groups=try h.groups()
        for mode in ["gtid","file-position"] {
            let path=try directory(), c=try f.config(path.path,mode:mode)
            var store: StateStore?=try StateStore(configuration:c)
            try store!.bindTargetIdentity(f.target); try store!.running()
            try f.apply(groups[0],to:store!)
            try pending(groups[1],store!); store=nil
            let relay=try Data(contentsOf:path.appendingPathComponent("relay.frames"))
            let db=path.appendingPathComponent("state.sqlite")
            let counters=try h.sqlite(db,"SELECT applied_sequence,transactions_applied,rows_applied,ddl_applied,last_applied_at FROM state")
            let schemas=try h.sqlite(db,"SELECT * FROM schemas")
            // Latest snapshot is still the baseline, so the applied delta must survive.
            XCTAssertEqual(try h.sqlite(db,"SELECT gtids FROM snapshots ORDER BY id DESC LIMIT 1"),[[h.sid+":1-10"]])
            let summary=try ApplySkip.run(configuration:c,gtidSet:h.sid.uppercased()+":12-12")
            XCTAssertEqual(summary.resumeGTIDSet,h.sid+":1-12")
            XCTAssertEqual(summary.resumePosition,groups[1].end)
            XCTAssertEqual(summary.skippedGTIDSet,h.sid+":12")
            XCTAssertEqual(try h.sqlite(db,"SELECT applied_sequence,transactions_applied,rows_applied,ddl_applied,last_applied_at FROM state"),counters)
            XCTAssertEqual(try h.sqlite(db,"SELECT * FROM schemas"),schemas)
            XCTAssertEqual(try Data(contentsOf:path.appendingPathComponent("relay.frames")),relay)
            XCTAssertEqual(try h.sqlite(db,"SELECT lifecycle,active_gtid,diagnostic FROM state"),[["STOPPED","NULL","NULL"]])
            XCTAssertEqual(try h.sqlite(db,"SELECT status FROM groups"),[["APPLIED"]])
            let resumed=try StateStore(configuration:c,initialize:false)
            let capture=try resumed.captureConfiguration(c.source)
            XCTAssertEqual(capture.start.position,UInt32(groups[1].end.position))
            XCTAssertEqual(capture.start.executedGTIDs,h.sid+":1-12")
            try resumed.running(); try f.apply(groups[2],to:resumed); try resumed.stopped()
            XCTAssertEqual(resumed.transactions,2); XCTAssertEqual(resumed.gtids,h.sid+":1-13")
        }
    }
    func testSkipFirstGroupPreservesDisjointMultipleSIDBaselineAndRestarts() throws {
        let f=fixture, h=f.helper, groups=try h.groups(), path=try directory()
        let baseline="00000000-0000-0000-0000-000000000001:7:9-11,"+h.sid+":1-5:8-10"
        let c=try f.config(path.path,gtids:baseline)
        var store: StateStore?=try StateStore(configuration:c)
        try store!.bindTargetIdentity(f.target); try pending(groups[0],store!); store=nil
        let result=try ApplySkip.run(configuration:c,gtidSet:h.sid+":11")
        XCTAssertEqual(result.resumeGTIDSet,"00000000-0000-0000-0000-000000000001:7:9-11,"+h.sid+":1-5:8-11")
        var resumed: StateStore?=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(resumed!.transactions,0); XCTAssertEqual(resumed!.applied,groups[0].end)
        try resumed!.stopped(); resumed=nil
        XCTAssertNoThrow(try StateStore(configuration:c,initialize:false))
        XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11"))
    }
    func testWrongEmptyMalformedAndBroaderSetsLeaveBlockedStateUnchanged() throws {
        let f=fixture, h=f.helper, path=try directory(), c=try f.config(path.path)
        var store: StateStore?=try StateStore(configuration:c)
        try store!.bindTargetIdentity(f.target); try pending(h.groups()[0],store!); store=nil
        let before=try dump(path)
        for set in ["", "bad", h.sid+":10", h.sid+":12", h.sid+":11-12", h.sid+":1-11", h.sid+":11,00000000-0000-0000-0000-000000000001:1"] {
            XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:set),set)
            XCTAssertEqual(try dump(path),before,set)
        }
    }
    func testAnyRowOrDDLIntentIncludingDoneRefusesSkip() throws {
        let f=fixture, h=f.helper
        for table in ["row_intents","ddl_intents"] {
            for status in ["PENDING","DONE"] {
                let path=try directory(), c=try f.config(path.path)
                var store: StateStore?=try StateStore(configuration:c)
                try store!.bindTargetIdentity(f.target); try pending(h.groups()[0],store!); store=nil
                let sql=table == "row_intents"
                    ? "INSERT INTO row_intents VALUES('\(h.sid):11',0,'4',0,1,'\(status)','now',NULL)"
                    : "INSERT INTO ddl_intents(gtid,target_sql,status,created_at) VALUES('\(h.sid):11','CREATE TABLE t(id INT)','\(status)','now')"
                try f.write(path,sql)
                let before=try dump(path)
                XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11")) { XCTAssertTrue(String(describing:$0).contains("target write intents")) }
                XCTAssertEqual(try dump(path),before)
            }
        }
    }
    func testSkipHonorsWriterLockAndRequiresExistingBlockedCapturedGroup() throws {
        let f=fixture, h=f.helper, path=try directory(), c=try f.config(path.path)
        XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        var store: StateStore?=try StateStore(configuration:c)
        try store!.bindTargetIdentity(f.target); try pending(h.groups()[0],store!)
        XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11")) { XCTAssertTrue(String(describing:$0).contains("active writer")) }
        store=nil
        try f.write(path,"DELETE FROM groups")
        XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11"))
    }
    func testCorruptProgressHistoryAndRelayBoundsRefuseWithoutMutation() throws {
        let f=fixture, h=f.helper, groups=try h.groups()
        for sql in [
            "DELETE FROM snapshots",
            "DELETE FROM groups WHERE status='APPLIED'",
            "UPDATE snapshots SET gtids=''",
            "UPDATE groups SET end_position=start_position WHERE status='PENDING'",
            "UPDATE groups SET relay_end=0 WHERE status='PENDING'",
            "UPDATE state SET durable_relay_length=durable_relay_length+1",
            "UPDATE state SET target_uuid=NULL",
            "UPDATE state SET source_uuid='00000000-0000-0000-0000-000000000002'",
            "UPDATE state SET lifecycle='RUNNING'",
            "UPDATE state SET active_gtid=NULL"
        ] {
            let path=try directory(), c=try f.config(path.path)
            var store: StateStore?=try StateStore(configuration:c)
            try store!.bindTargetIdentity(f.target); try f.apply(groups[0],to:store!)
            try pending(groups[1],store!); store=nil
            try f.write(path,sql); let before=try dump(path)
            XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":12"),sql)
            XCTAssertEqual(try dump(path),before,sql)
        }
    }
    func testSQLiteFailureRollsBackDeleteSnapshotAndCheckpointTogether() throws {
        let f=fixture, h=f.helper, path=try directory(), c=try f.config(path.path)
        var store: StateStore?=try StateStore(configuration:c)
        try store!.bindTargetIdentity(f.target); try pending(h.groups()[0],store!); store=nil
        try f.write(path,"CREATE TRIGGER reject_skip BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'test fault'); END")
        let before=try dump(path)
        XCTAssertThrowsError(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11"))
        XCTAssertEqual(try dump(path),before)
        try f.write(path,"DROP TRIGGER reject_skip")
        XCTAssertNoThrow(try ApplySkip.run(configuration:c,gtidSet:h.sid+":11"))
    }
}
