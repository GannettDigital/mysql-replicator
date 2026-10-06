import XCTest
import MySQLNIO
import NIOCore
import ReplicatorCapture
@testable import ReplicatorApply

final class TargetReconnectTests: XCTestCase {
    func testOnlyTransportFailuresAreRetryable() {
        XCTAssertTrue(isTargetTransportFailure(MySQLError.closed))
        XCTAssertTrue(isTargetTransportFailure(ChannelError.ioOnClosedChannel))
        XCTAssertFalse(isTargetTransportFailure(MySQLError.invalidSyntax("bad SQL")))
        XCTAssertFalse(isTargetTransportFailure(MySQLError.duplicateEntry("duplicate")))
        XCTAssertFalse(isTargetTransportFailure(ApplyError("connection closed")))
    }
    func testDrainStopsConsumerWithoutInterruptingJournaledWorker() throws {
        let queue=ApplyQueue<Int>()
        try queue.push(1,bytes:1,cancellation:.init())
        queue.finish(.failure(ApplyDrainRequested()))
        XCTAssertNoThrow(try queue.checkFailure(allowDrain:true))
        XCTAssertThrowsError(try queue.next(onWait:{}))
        XCTAssertEqual(queue.snapshot.queuedItems,0)
    }
    func testDrainInterruptsReconnectBackoff() {
        let drain=CaptureCancellation(), done=expectation(description:"drain")
        DispatchQueue.global().async {
            SourceRetryState.wait(seconds:30,cancellation:.init(),drain:drain); done.fulfill()
        }
        drain.cancel(); wait(for:[done],timeout:1)
    }
}

extension ApplyTests {
    func testTargetReadFailureDiscardsOnlyEntireUnissuedGroups() throws {
        try withBatchFixture { state,batch in
            try state.beginBatch(batch)
            var calls=0
            let outcome=DMLExecution.run(batch,cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                lock:{ _ in calls += 1; if calls == 2 { throw TargetConnectionFailure(description:"closed before write") } },
                write:{ _ in },insert:{ _ in XCTFail() },completedGroup:{},trace:{ .init() })
            XCTAssertTrue(outcome.discardUnwritten)
            XCTAssertThrowsError(try outcome.record(in:state))
            XCTAssertEqual(state.transactions,1); XCTAssertNil(state.pendingGTID)
            try state.discardUnappliedCapture()
            XCTAssertEqual(state.relayLength,batch[0].relayEnd)
            let path=state.directory.appendingPathComponent("state.sqlite")
            XCTAssertEqual(try sqlite(path,"SELECT COUNT(*) FROM groups"),[["1"]])
            XCTAssertEqual(try sqlite(path,"SELECT COUNT(*) FROM target_failure"),[["1"]])
            XCTAssertEqual(outcome.diagnostic?.rows.map(\.disposition),["acknowledged","notIssued","notIssued","notIssued"])
        }
    }
    func testLostCombinedReplyKeepsEveryAffectedGTIDUncertain() throws {
        try withBatchFixture { state,input in
            let batch=input.map { PreparedDMLGroup(group:$0.group,mutations:input[0].mutations,relayEnd:$0.relayEnd) }
            try state.beginBatch(batch)
            var calls=0
            let outcome=DMLExecution.run(batch,cancellation:.init(),maximumInsertRows:2,maximumInsertBytes:1024*1024,
                lock:{ _ in },write:{ _ in XCTFail() },insert:{ _ in
                    calls += 1; if calls == 2 { throw TargetConnectionFailure(description:"lost reply") }
                },completedGroup:{},trace:{ .init(phase:.possiblyExecuted,sql:"INSERT INTO t VALUES (?),(?)") })
            XCTAssertFalse(outcome.discardUnwritten)
            XCTAssertThrowsError(try outcome.record(in:state))
            XCTAssertEqual(state.transactions,2); XCTAssertEqual(state.pendingGTID,batch[2].id)
            XCTAssertEqual(outcome.diagnostic?.rows.map(\.disposition),["acknowledged","acknowledged","possiblyExecuted","possiblyExecuted"])
            XCTAssertEqual(outcome.diagnostic?.rows.suffix(2).map(\.gtid),batch.suffix(2).map(\.id))
            XCTAssertThrowsError(try state.discardUnappliedCapture())
        }
    }
    func testReadFailureInsidePartiallyAcknowledgedGroupStaysBlocked() throws {
        try withBatchFixture { state,input in
            let group=PreparedDMLGroup(group:input[0].group,mutations:Array(repeating:input[0].mutations[0],count:3),relayEnd:input[0].relayEnd)
            try state.beginBatch([group])
            var calls=0
            let outcome=DMLExecution.run([group],cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                lock:{ _ in },write:{ _ in
                    calls += 1; if calls == 2 { throw TargetConnectionFailure(description:"closed before next write") }
                },insert:{ _ in XCTFail() },completedGroup:{},trace:{ .init() })
            XCTAssertFalse(outcome.discardUnwritten)
            XCTAssertThrowsError(try outcome.record(in:state))
            XCTAssertEqual(state.transactions,0); XCTAssertEqual(state.pendingGTID,group.id)
            XCTAssertThrowsError(try state.discardUnwrittenPending())
            XCTAssertEqual(outcome.diagnostic?.rows.map(\.disposition),["acknowledged","notIssued"])
        }
    }
    func testSuccessfulWriteThenUnlockFailureRetainsCheckpoint() throws {
        try withBatchFixture { state,batch in
            try state.beginBatch([batch[0]])
            let outcome=DMLExecution.run([batch[0]],cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                lock:{ _ in },write:{ _ in },insert:{ _ in XCTFail() },completedGroup:{ throw TargetConnectionFailure(description:"unlock disconnected") },
                trace:{ .init(phase:.acknowledged,sql:"INSERT INTO t VALUES (?)") })
            XCTAssertThrowsError(try outcome.record(in:state))
            XCTAssertEqual(state.transactions,1); XCTAssertNil(state.pendingGTID)
            XCTAssertEqual(outcome.diagnostic?.rows.map(\.disposition),["acknowledged"])
            XCTAssertNoThrow(try state.discardUnappliedCapture())
        }
    }
}
