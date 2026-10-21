import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture

final class ProgressEstimateTests: XCTestCase {
    let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    func testReplayEndpointRateAndPause() throws {
        let e = ProgressEstimator(window: 60)
        let first = e.update(
            now: 0, transactions: 0, bytes: 0, completed: sid + ":1-100", goal: sid + ":200", replay: true,
            lifecycle: "RUNNING")
        XCTAssertEqual(first.remainingTransactions, 100)
        XCTAssertEqual(first.status, "collectingRateSample")
        let second = e.update(
            now: 10, transactions: 20, bytes: 2000, completed: sid + ":1-120", goal: sid + ":200", replay: true,
            lifecycle: "RUNNING")
        XCTAssertEqual(second.remainingTransactions, 80)
        XCTAssertEqual(second.transactionsPerSecond, 2)
        XCTAssertEqual(second.estimatedSecondsRemaining, 40)
        XCTAssertEqual(second.binlogBytesPerSecond, 200)
        XCTAssertEqual(
            e.update(
                now: 11, transactions: 20, bytes: 2000, completed: sid + ":1-120", goal: sid + ":200", replay: true,
                lifecycle: "BLOCKED"
            ).status, "paused")
        let done = e.update(
            now: 12, transactions: 100, bytes: 10000, completed: sid + ":1-200", goal: sid + ":200", replay: true,
            lifecycle: "STOPPED")
        XCTAssertEqual(done.estimatedSecondsRemaining, 0)
    }
    func testSparseSamplesStallAndCounterOrClockReset() {
        let e = ProgressEstimator(window: 60)
        func update(_ time: Double, _ count: Int, _ lifecycle: String = "RUNNING") -> ProgressEstimate {
            e.update(
                now: time, transactions: count, bytes: Int64(count * 10), completed: sid + ":1-\(100 + count)",
                goal: sid + ":200", replay: true, lifecycle: lifecycle)
        }
        _ = update(0, 0)
        let sparse = update(10, 1)
        XCTAssertEqual(sparse.sampleDurationSeconds, 10)
        XCTAssertEqual(sparse.sampleTransactions, 1)
        XCTAssertEqual(sparse.estimatedSecondsRemaining, 990)
        XCTAssertTrue(sparse.provisional)
        let measured = update(20, 20)
        XCTAssertFalse(measured.provisional)
        XCTAssertEqual(measured.sampleTransactions, 20)
        XCTAssertEqual(update(21, 20, "TARGET_RECONNECTING").status, "paused")
        XCTAssertNil(update(22, 20, "RECONNECTING").estimatedSecondsRemaining)
        _ = update(90, 20)
        let stalled = update(151, 20)
        XCTAssertEqual(stalled.status, "noRecentProgress")
        XCTAssertEqual(stalled.sampleTransactions, 0)
        XCTAssertNil(stalled.estimatedSecondsRemaining)
        let clockReset = update(1, 21)
        XCTAssertEqual(clockReset.sampleDurationSeconds, 0)
        XCTAssertEqual(clockReset.transactionsPerSecond, 0)
        let counterReset = update(2, 0)
        XCTAssertEqual(counterReset.sampleTransactions, 0)
        XCTAssertEqual(counterReset.binlogBytesPerSecond, 0)
    }
    func testTaggedIntervalsAndHolesAreSeparate() throws {
        let goal = try GTIDSet(sid + ":1-10:blue:1-10:green:1-2")
        let done = try GTIDSet(sid + ":1-3:5-10:blue:1-5")
        XCTAssertEqual(goal.remainingTransactions(after: done), 8)
        XCTAssertEqual(try GTIDSet(sid + ":10").remainingTransactions(after: done), 0)
        XCTAssertEqual(try GTIDSet(sid + ":10").remainingTransactions(after: done, throughEndpoints: true), 1)
    }
    func testInventoryUsesActualFileSizes() {
        let source = SourceObservation(
            observedAt: 0, executedGTIDs: sid + ":1-5", file: "binlog.3", position: 90,
            files: [
                .init(name: "binlog.1", bytes: 100), .init(name: "binlog.2", bytes: 500),
                .init(name: "binlog.3", bytes: 150),
            ])
        XCTAssertEqual(source.bytesRemaining(after: .init(file: "binlog.1", position: 40)), 650)
        XCTAssertEqual(source.bytesRemaining(after: .init(file: "binlog.3", position: 80)), 10)
        XCTAssertNil(source.bytesRemaining(after: .init(file: "purged", position: 4)))
    }
    func testLiveRateSubtractsSourceGrowth() throws {
        let e = ProgressEstimator(window: 60)
        func source(_ t: Double, _ n: Int) -> SourceObservation {
            .init(observedAt: t, executedGTIDs: sid + ":1-\(n)", file: "b", position: 4, files: [])
        }
        _ = e.update(
            now: 0, transactions: 0, bytes: 0, completed: sid + ":1-10", goal: sid + ":1-100", replay: false,
            lifecycle: "RUNNING", observation: source(0, 100))
        let v = e.update(
            now: 10, transactions: 20, bytes: 1000, completed: sid + ":1-30", goal: sid + ":1-110", replay: false,
            lifecycle: "RUNNING", observation: source(10, 110))
        XCTAssertEqual(v.estimatedSecondsRemaining, 80)
    }
}
