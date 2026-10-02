import XCTest
import ReplicatorCapture
import ReplicatorCodec
@testable import ReplicatorApply

final class PipelineTests: XCTestCase {
    func testQueueDrainsSuccessfulProducerInOrder() throws {
        let queue = ApplyQueue<Int>(byteLimit:8,itemLimit:3,groupLimit:2)
        try queue.push(1,bytes:3,groups:1,cancellation:.init())
        try queue.push(2,bytes:5,groups:1,cancellation:.init())
        queue.finish(.success(()))
        XCTAssertEqual(try queue.next(onWait:{}),1)
        XCTAssertEqual(try queue.next(onWait:{}),2)
        XCTAssertNil(try queue.next(onWait:{}))
        XCTAssertEqual(queue.snapshot.maximumBytes,8)
        XCTAssertEqual(queue.snapshot.maximumGroups,2)
        XCTAssertEqual(queue.snapshot.groupsDequeued,2)
        XCTAssertEqual(queue.snapshot.queuedBytes,0)
    }

    func testEachQueueLimitBackpressuresAndReleasesProducer() throws {
        for (bytes,items,groups) in [(1,10,10),(10,1,10),(10,10,1)] {
            let queue = ApplyQueue<Int>(byteLimit:bytes,itemLimit:items,groupLimit:groups)
            try queue.push(1,bytes:1,groups:1,cancellation:.init())
            let entered = DispatchSemaphore(value:0), pushed = DispatchSemaphore(value:0)
            let finished = expectation(description:"producer joined")
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                entered.signal()
                do { try queue.push(2,bytes:1,groups:1,cancellation:.init()); pushed.signal() }
                catch { XCTFail("unexpected producer failure: \(error)") }
            }
            XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
            XCTAssertEqual(pushed.wait(timeout:.now()+0.05),.timedOut)
            XCTAssertEqual(try queue.next(onWait:{}),1)
            XCTAssertEqual(pushed.wait(timeout:.now()+2),.success)
            queue.finish(.success(()))
            XCTAssertEqual(try queue.next(onWait:{}),2)
            XCTAssertLessThanOrEqual(queue.snapshot.maximumBytes,bytes)
            XCTAssertLessThanOrEqual(queue.snapshot.maximumItems,items)
            XCTAssertLessThanOrEqual(queue.snapshot.maximumGroups,groups)
            wait(for:[finished],timeout:2)
        }
    }

    func testFailureDiscardsQueuedWorkAndUnblocksFullProducer() throws {
        let queue = ApplyQueue<Int>(byteLimit:1)
        try queue.push(1,bytes:1,cancellation:.init())
        let started = DispatchSemaphore(value:0), finished = expectation(description:"failed producer")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            started.signal()
            do { try queue.push(2,bytes:1,cancellation:.init()); XCTFail("producer ignored failure") }
            catch { XCTAssertEqual(String(describing:error),"target failed") }
        }
        XCTAssertEqual(started.wait(timeout:.now()+2),.success)
        queue.finish(.failure(ApplyError("target failed")))
        queue.finish(.failure(ApplyError("secondary cancellation")))
        XCTAssertThrowsError(try queue.next(onWait:{})) { XCTAssertEqual(String(describing:$0),"target failed") }
        XCTAssertEqual(queue.snapshot.queuedItems,0)
        XCTAssertEqual(queue.snapshot.queuedBytes,0)
        wait(for:[finished],timeout:2)
    }

    func testCancellationUnblocksFullQueueWithoutCancellingParent() throws {
        let parent = CaptureCancellation(), child = CaptureCancellation(parent:parent)
        let queue = ApplyQueue<Int>(byteLimit:1)
        try queue.push(1,bytes:1,cancellation:child)
        let finished = expectation(description:"cancelled producer")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try queue.push(2,bytes:1,cancellation:child); XCTFail("producer ignored cancellation") }
            catch { XCTAssertTrue(error is CaptureCancelled) }
        }
        child.cancel()
        wait(for:[finished],timeout:2)
        XCTAssertFalse(parent.isCancelled)
        let another = CaptureCancellation(parent:parent)
        parent.cancel(); XCTAssertTrue(another.isCancelled)
        XCTAssertThrowsError(try queue.push(3,bytes:2,cancellation:.init()))
    }

    func testPipelineOverlapsWorkersAndJoinsBeforeReturning() throws {
        let pipeline = ApplyPipeline(), producer = StageTimings(), consumer = StageTimings()
        let consumed = DispatchSemaphore(value:0)
        let consumerThread = Thread.current
        var messages = 0
        try pipeline.run(cancellation:.init(),producerTimings:producer,produce:{ _,send in
            XCTAssertFalse(Thread.current === consumerThread)
            try send(.idle)
            // This cannot complete if production and consumption share a loop.
            guard consumed.wait(timeout:.now()+2) == .success else { throw ApplyError("consumer did not overlap") }
            try send(.idle)
        },consume:{ _ in
            XCTAssertTrue(Thread.current === consumerThread)
            messages += 1; consumed.signal()
        },onWait:{},timings:consumer)
        XCTAssertEqual(messages,2)
        XCTAssertEqual(producer.snapshot["pipeline.enqueue"]?.count,2)
        XCTAssertEqual(pipeline.queue.snapshot.queuedItems,0)
    }

    func testConsumerFailureStopsAndJoinsProducerPreservingOriginalError() {
        let pipeline = ApplyPipeline(), stopped = expectation(description:"producer stopped")
        XCTAssertThrowsError(try pipeline.run(cancellation:.init(),producerTimings:.init(),produce:{ stop,send in
            defer { stopped.fulfill() }
            try send(.idle)
            while !stop.isCancelled { try send(.idle) }
        },consume:{ _ in throw ApplyError("uncertain SQL") },onWait:{},timings:.init())) {
            XCTAssertEqual(String(describing:$0),"uncertain SQL")
        }
        wait(for:[stopped],timeout:0.1)
    }

    func testProducerFailureWakesEmptyConsumerAndIsNotHiddenByStop() {
        let pipeline = ApplyPipeline()
        XCTAssertThrowsError(try pipeline.run(cancellation:.init(),producerTimings:.init(),produce:{ _,_ in
            throw ApplyError("bad checksum")
        },consume:{ _ in XCTFail("unexpected work") },onWait:{},timings:.init())) {
            XCTAssertEqual(String(describing:$0),"bad checksum")
        }
    }
}
