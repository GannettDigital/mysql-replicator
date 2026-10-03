import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

private func disconnected() -> LiveInspectionError {
    LiveInspectionError(error:SourceTransportError("source disconnected"),summary:LiveSummary(transactions:0,events:0,
        eventBytesReceived:"0",heartbeats:0,rotationAnnouncements:0,lastCompleteBoundary:nil,
        pendingTransactionStart:BinlogCoordinate(file:"binlog.000003",position:1589),completeGTIDSet:""))
}

final class SourceReconnectTests: XCTestCase {
    func testBackoffCapsAndBudgetResetsOnlyAfterAppliedProgress() throws {
        var policy=SourceReconnectPolicy(); policy.maximumDelaySeconds=3; policy.maximumAttempts=4
        var retry=SourceRetryState(policy:policy)
        XCTAssertEqual(try (0..<4).map { _ in try retry.nextDelay(appliedTransactions:7) },[1,2,3,3])
        XCTAssertThrowsError(try retry.nextDelay(appliedTransactions:7))
        XCTAssertEqual(try retry.nextDelay(appliedTransactions:8),1)
        XCTAssertEqual(retry.attempts,5)
        policy.enabled=false
        var disabled=SourceRetryState(policy:policy)
        XCTAssertThrowsError(try disabled.nextDelay(appliedTransactions:0))
        for json in [#"{"initialDelaySeconds":0}"#,#"{"maximumDelaySeconds":0}"#,#"{"maximumAttempts":-1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(SourceReconnectPolicy.self,from:Data(json.utf8)).validate())
        }
    }
    func testBackoffIsInterruptible() {
        let stop=CaptureCancellation(), done=expectation(description:"backoff cancelled")
        DispatchQueue.global().async { SourceRetryState.wait(seconds:30,cancellation:stop); done.fulfill() }
        stop.cancel(); wait(for:[done],timeout:1)
    }
    func testSourceFailureDoesNotCancelJournaledExecutionButStillStopsConsumer() throws {
        let queue=ApplyQueue<Int>()
        try queue.push(1,bytes:1,cancellation:.init())
        queue.finish(.failure(disconnected()))
        XCTAssertNoThrow(try queue.checkFailure(allowSourceReconnect:true))
        XCTAssertThrowsError(try queue.checkFailure())
        XCTAssertThrowsError(try queue.next(onWait:{}))
        XCTAssertEqual(queue.snapshot.queuedItems,0)
        queue.finish(.failure(ApplyError("target write failed")))
        XCTAssertThrowsError(try queue.checkFailure(allowSourceReconnect:true))
        let target=ApplyQueue<Int>(); target.finish(.failure(ApplyError("target write failed")))
        XCTAssertThrowsError(try target.checkFailure(allowSourceReconnect:true))
    }
    func testConcurrentSourceFailureCannotMaskConsumerFailure() {
        let pipeline=ApplyPipeline(), entered=DispatchSemaphore(value:0)
        XCTAssertThrowsError(try pipeline.run(cancellation:.init(),producerTimings:.init(),produce:{ _,send in
            try send(.idle)
            guard entered.wait(timeout:.now()+2) == .success else { throw ApplyError("consumer timeout") }
            throw disconnected()
        },consume:{ _ in
            entered.signal()
            let deadline=Date().addingTimeInterval(2)
            while true {
                do { try pipeline.queue.checkFailure() }
                catch { break }
                if Date() >= deadline { XCTFail("producer did not fail"); break }
                Thread.sleep(forTimeInterval:0.001)
            }
            throw ApplyError("uncertain target response")
        },onWait:{},timings:.init())) {
            XCTAssertEqual(String(describing:$0),"uncertain target response")
        }
    }
}

extension ApplyTests {
    func testReconnectKeepsAcknowledgedBatchAndDiscardsOnlyUnappliedRelay() throws {
        try withBatchFixture { store,batch in
            let original=try Data(contentsOf:store.directory.appendingPathComponent("relay.frames"))
            try store.beginBatch(Array(batch.prefix(2)))
            let queue=ApplyQueue<Int>(); var writes=0
            let outcome=DMLExecution.run(Array(batch.prefix(2)),cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                lock:{ _ in try queue.checkFailure(allowSourceReconnect:true) },write:{ _ in
                    try queue.checkFailure(allowSourceReconnect:true); writes += 1
                    queue.finish(.failure(disconnected()))
                },insert:{ _ in XCTFail() },completedGroup:{})
            try outcome.record(in:store)
            XCTAssertEqual(writes,2); XCTAssertEqual(store.transactions,2)
            try store.ensureCapacity() // Sample the longer, not-yet-trimmed tail.
            try store.discardUnappliedCapture()
            XCTAssertEqual(store.relayLength,batch[1].relayEnd)
            XCTAssertEqual(try Data(contentsOf:store.directory.appendingPathComponent("relay.frames")),Data(original.prefix(Int(batch[1].relayEnd))))
            let capture=try store.captureConfiguration(config().source,remainingTransactions:2)
            XCTAssertEqual(capture.start.file,batch[1].group.end.file)
            XCTAssertEqual(capture.start.position,UInt32(batch[1].group.end.position))
            XCTAssertEqual(capture.start.executedGTIDs,try store.durableAppliedGTIDs())
            XCTAssertEqual(capture.stopAfterTransactions,2)
            // Replayed work appends at the trimmed offset and keeps valid journal ranges.
            for item in batch.dropFirst(2) {
                for event in item.group.events { try store.append(LiveRecord(kind:"event",file:item.group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
            }
            try store.beginBatch(Array(batch.dropFirst(2)))
            try store.finishBatch(acknowledgedRows:[1,1])
            XCTAssertEqual(store.transactions,4); XCTAssertNil(store.pendingGTID)
        }
    }
    func testReconnectRefusesPartiallyAcknowledgedTargetBatch() throws {
        try withBatchFixture { store,batch in
            try store.beginBatch(batch)
            try store.finishBatch(acknowledgedRows:[1,0,0,0])
            let length=store.relayLength
            XCTAssertThrowsError(try store.discardUnappliedCapture())
            XCTAssertEqual(store.relayLength,length)
            XCTAssertEqual(store.pendingGTID,batch[1].id)
        }
    }
    func testReconnectBeforeFirstAppliedGroupReturnsToBaseline() throws {
        try withBatchFixture { store,_ in
            try store.discardUnappliedCapture()
            XCTAssertEqual(store.relayLength,0); XCTAssertNil(store.applied)
            XCTAssertEqual(try store.captureConfiguration(config().source).start.executedGTIDs,sid+":1-10")
        }
    }
}
