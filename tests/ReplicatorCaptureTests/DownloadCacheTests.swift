import XCTest
@testable import ReplicatorCapture
import ReplicatorCodec

final class DownloadCacheTests: XCTestCase {
    let frame=Data(repeating:42,count:32)

    func testPublishedBatchesDrainInOrderWithoutDurableCheckpoint() throws {
        let cache=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
        let stop=CaptureCancellation(), writer=StageTimings(), reader=StageTimings()
        try cache.append([frame,Data(repeating:7,count:19)],cancellation:stop,timings:writer)
        try cache.append([frame],cancellation:stop,timings:writer)
        cache.finish(.success(()),elapsed:1)
        XCTAssertEqual(try cache.next(cancellation:stop,timings:reader),[frame,Data(repeating:7,count:19)])
        XCTAssertEqual(try cache.next(cancellation:stop,timings:reader),[frame])
        XCTAssertNil(try cache.next(cancellation:stop,timings:reader))
        XCTAssertEqual(cache.snapshot.frames,3)
        XCTAssertEqual(cache.snapshot.eventBytes,83)
        XCTAssertEqual(cache.snapshot.queuedBytes,0)
        XCTAssertTrue(cache.snapshot.reachedEOF)
        XCTAssertFalse(cache.snapshot.durable)
        XCTAssertEqual(writer.snapshot["download.write"]?.count,2)
        XCTAssertEqual(reader.snapshot["download.read"]?.count,2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cache.directory.path).isEmpty)
    }
    func testFailureDoesNotDrainQueuedFramesOrMasqueradeAsCancellation() throws {
        let cache=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
        let stop=CaptureCancellation()
        try cache.append([frame],cancellation:stop,timings:StageTimings())
        cache.finish(.failure(CaptureError("source lost")))
        stop.cancel()
        XCTAssertThrowsError(try cache.next(cancellation:stop,timings:StageTimings())) {
            XCTAssertEqual(String(describing:$0),"source lost")
        }
    }
    func testFullCacheBackpressuresReceiverThenUnblocksOnRead() throws {
        let cache=try DownloadCache(maximumBytes:68,maximumEventBytes:64,maximumBatches:1)
        let stop=CaptureCancellation()
        try cache.append([frame],cancellation:stop,timings:StageTimings())
        let started=DispatchSemaphore(value:0), done=DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            started.signal()
            do { try cache.append([self.frame],cancellation:stop,timings:StageTimings()) }
            catch { XCTFail(String(describing:error)) }
            done.signal()
        }
        XCTAssertEqual(started.wait(timeout:.now()+2),.success)
        XCTAssertEqual(done.wait(timeout:.now()+0.1),.timedOut)
        XCTAssertEqual(try cache.next(cancellation:stop,timings:StageTimings()),[frame])
        XCTAssertEqual(done.wait(timeout:.now()+2),.success)
        XCTAssertLessThanOrEqual(cache.snapshot.maximumQueuedBytes,68)
        XCTAssertEqual(cache.snapshot.maximumQueuedBatches,1)
        XCTAssertEqual(try cache.next(cancellation:stop,timings:StageTimings()),[frame])
    }
    func testCancellationUnblocksFullCacheAndEmptyConsumer() throws {
        let cache=try DownloadCache(maximumBytes:68,maximumEventBytes:64,maximumBatches:1)
        let stop=CaptureCancellation()
        try cache.append([frame],cancellation:stop,timings:StageTimings())
        let done=DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            do { try cache.append([self.frame],cancellation:stop,timings:StageTimings()); XCTFail("cancelled write succeeded") }
            catch { XCTAssertTrue(error is CaptureCancelled) }
            done.signal()
        }
        stop.cancel()
        XCTAssertEqual(done.wait(timeout:.now()+2),.success)
        let empty=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
        XCTAssertThrowsError(try empty.next(cancellation:stop,timings:StageTimings())) { XCTAssertTrue($0 is CaptureCancelled) }
    }
    func testLostOrTruncatedCacheFailsAndNewRunHasNoPublishedData() throws {
        for missing in [false,true] {
            let cache=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
            try cache.append([frame],cancellation:CaptureCancellation(),timings:StageTimings())
            let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:cache.directory,includingPropertiesForKeys:nil).first)
            if missing { try FileManager.default.removeItem(at:file) }
            else { try Data([1,2]).write(to:file) }
            XCTAssertThrowsError(try cache.next(cancellation:CaptureCancellation(),timings:StageTimings()))
            let fresh=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
            XCTAssertNotEqual(fresh.directory,cache.directory)
            XCTAssertEqual(fresh.snapshot.frames,0)
            fresh.finish(.success(())); XCTAssertNil(try fresh.next(cancellation:CaptureCancellation(),timings:StageTimings()))
        }
    }
    func testCacheIsRemovedWhenJoinedOwnerReleasesIt() throws {
        var cache:DownloadCache?=try DownloadCache(maximumBytes:128,maximumEventBytes:64)
        let directory=cache!.directory
        try cache!.append([frame],cancellation:CaptureCancellation(),timings:StageTimings())
        cache=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
}
