import Foundation
import ReplicatorCodec
import XCTest

@testable import ReplicatorApply

final class RunActivityTests: XCTestCase {
    func testMonotonicAgesNestedPhasesAndSeparatePositions() {
        var time = 10.0
        var wall = 1000.0
        let activity = RunActivity(uptime: { time }, wallTime: { wall })
        let applied = BinlogCoordinate(file: "binlog.1", position: 100)
        activity.resetPositions(to: applied)
        activity.checkpoint(transactions: 100)
        XCTAssertNil(activity.snapshot.lastProgressAt)  // The saved baseline is not new work.
        activity.begin(.target, "schemaDiscovery", table: .init(database: "db", table: "t"))
        time = 12
        activity.begin(.target, "schemaDiscovery", table: .init(database: "db", table: "parent"), purpose: "columns")
        activity.begin(.capture, "schemaWait")
        activity.didRead(.init(file: "binlog.2", position: 900))
        activity.didPrepare(.init(file: "binlog.1", position: 600))
        time = 15
        wall = 900  // A wall-clock correction must not change durations.
        var status = activity.snapshot
        XCTAssertEqual(status.generatedAt, 900)
        XCTAssertEqual(status.checkpointAgeSeconds, 5)
        XCTAssertEqual(status.phases["target"]?.elapsedSeconds, 3)
        XCTAssertEqual(status.phases["target"]?.table, "parent")
        XCTAssertEqual(status.phases["capture"]?.name, "schemaWait")
        XCTAssertEqual(status.readPosition?.file, "binlog.2")
        XCTAssertEqual(status.preparedPosition?.position, 600)
        activity.end(.target)
        XCTAssertEqual(activity.snapshot.phases["target"]?.elapsedSeconds, 5)
        activity.checkpoint(transactions: 101)
        time = 19
        wall = 5000
        activity.checkpoint(transactions: 101)
        status = activity.snapshot
        XCTAssertEqual(status.lastProgressAt, 900)
        XCTAssertEqual(status.secondsSinceLastProgress, 4)
        XCTAssertEqual(status.checkpointAgeSeconds, 0)
        activity.resetPositions(to: applied)  // Reconnect/reload discards queued work.
        XCTAssertEqual(activity.snapshot.readPosition, applied)
        XCTAssertEqual(activity.snapshot.preparedPosition, applied)
    }

    func testFailedPhaseRestoresParentAndAgesEstimateWithoutNewProgress() throws {
        var time = 0.0
        let activity = RunActivity(uptime: { time }, wallTime: { 0 })
        activity.checkpoint(transactions: 0)
        activity.begin(.coordinator, "running")
        XCTAssertThrowsError(
            try activity.measure(.coordinator, "archiveValidation") { throw ApplyError("fixture") })
        XCTAssertEqual(activity.snapshot.phases["coordinator"]?.name, "running")
        var progress = controlTestSummary("RUNNING")
        progress.estimate = ProgressEstimate(mode: "replay", status: "estimated", estimatedSecondsRemaining: 30)
        time = 65
        let refreshed = progress.refreshingActivity(from: activity)
        XCTAssertEqual(refreshed.estimate?.sampleAgeSeconds, 65)
        XCTAssertEqual(refreshed.estimate?.status, "staleRateSample")
        XCTAssertEqual(refreshed.estimate?.estimatedSecondsRemaining, 30)
        XCTAssertEqual(refreshed.estimate?.provisional, true)
        // Refreshing a reply must not move the checkpoint or mutate the cached sample.
        XCTAssertEqual(progress.estimate?.sampleAgeSeconds, 0)
        XCTAssertEqual(activity.snapshot.checkpointAgeSeconds, 65)
        progress.estimate?.mode = "live"
        progress.estimate?.sourceObservationAgeSeconds = 2
        let live = progress.refreshingActivity(from: activity)
        XCTAssertEqual(live.estimate?.sourceObservationAgeSeconds, 67)
        XCTAssertEqual(live.estimate?.sourceObservationStale, true)
        XCTAssertEqual(live.estimate?.status, "staleSourceSample")
        XCTAssertEqual(
            controlTestSummary("STOPPED").refreshingActivity(from: activity).activity?.phases.count, 0)
    }
}
