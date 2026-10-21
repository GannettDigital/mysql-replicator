import Foundation
import ReplicatorCapture

public struct StatisticsPolicy: Decodable {
    public var sourcePollIntervalSeconds: Int = 15
    public var rateWindowSeconds: Int = 60
    public var tableDetails = false
    public var maximumTableEntries = 6000
    public var snapshotIntervalSeconds = 30
    public init() {}
    enum CodingKeys: String, CodingKey {
        case sourcePollIntervalSeconds, rateWindowSeconds, tableDetails, maximumTableEntries, snapshotIntervalSeconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .sourcePollIntervalSeconds) ?? 15
        rateWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .rateWindowSeconds) ?? 60
        tableDetails = try c.decodeIfPresent(Bool.self, forKey: .tableDetails) ?? false
        maximumTableEntries = try c.decodeIfPresent(Int.self, forKey: .maximumTableEntries) ?? 6000
        snapshotIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .snapshotIntervalSeconds) ?? 30
    }
    func validate() throws {
        try require(
            (1...100000).contains(maximumTableEntries), "statistics.maximumTableEntries must be 1 through 100000")
        try require(
            (5...3600).contains(snapshotIntervalSeconds), "statistics.snapshotIntervalSeconds must be 5 through 3600")
        try require(
            (5...3600).contains(sourcePollIntervalSeconds) && (5...3600).contains(rateWindowSeconds),
            "statistics intervals must be 5 through 3600 seconds")
    }
}
public struct ProgressEstimate: Encodable {
    public var mode: String
    public var status: String
    public var goalGTIDSet: String?
    public var remainingTransactions: UInt64?
    public var transactionsPerSecond: Double = 0
    public var binlogBytesPerSecond: Double = 0
    public var estimatedSecondsRemaining: Double?
    public var remainingBinlogBytes: UInt64?
    public var sourceObservation: SourceObservation?
    public var sourceObservationAgeSeconds: Double?
    public var sourceObservationStale: Bool = false
    public var sourceObservationStaleAfterSeconds: Int = 30
    public var sampleDurationSeconds: Double = 0
    public var sampleTransactions: Int = 0
    public var sampleAgeSeconds: Double = 0
    public var rateWindowSeconds: Int = 60
    public var provisional: Bool = true
    public var monitoringError: String?
}
/// Use monotonic time for rates. GTID set counts include filtered/skipped groups.
final class ProgressEstimator {
    private struct Sample {
        let time: Double
        let transactions: Int
        let bytes: Int64
    }
    private var samples: [Sample] = []
    private let window: Double
    private var sourceRate: Double = 0
    private var priorSource: SourceObservation?
    init(window: Int) { self.window = Double(window) }
    func update(
        now: Double, transactions: Int, bytes: Int64, completed: String, goal: String?, replay: Bool, lifecycle: String,
        observation: SourceObservation? = nil
    ) -> ProgressEstimate {
        if let last = samples.last, now < last.time || transactions < last.transactions || bytes < last.bytes {
            samples.removeAll()
        }
        let sample = Sample(time: now, transactions: transactions, bytes: bytes)
        if let last = samples.last, now - last.time < 0.25 { /* Keep bounded sampling at frequent DDL boundaries. */
        } else {
            samples.append(sample)
        }
        while samples.count > 2 && samples[1].time < now - window { samples.removeFirst() }
        var result = ProgressEstimate(
            mode: replay ? "replay" : "live", status: "collectingRateSample", goalGTIDSet: goal)
        result.rateWindowSeconds = Int(window)
        if let first = samples.first {
            result.sampleDurationSeconds = max(0, now - first.time)
            result.sampleTransactions = max(0, transactions - first.transactions)
            result.provisional = result.sampleDurationSeconds < 5 || result.sampleTransactions < 20
        }
        if let first = samples.first, now - first.time >= 1 {
            result.transactionsPerSecond = max(0, Double(transactions - first.transactions) / (now - first.time))
            result.binlogBytesPerSecond = max(0, Double(bytes - first.bytes) / (now - first.time))
        }
        if let observation, observation.observedAt != priorSource?.observedAt {
            if let previous = priorSource, observation.observedAt > previous.observedAt,
                let next = try? GTIDSet(observation.executedGTIDs), let old = try? GTIDSet(previous.executedGTIDs)
            {
                sourceRate =
                    Double(next.remainingTransactions(after: old)) / (observation.observedAt - previous.observedAt)
            }
            priorSource = observation
        }
        if let goal, let set = try? GTIDSet(goal), let done = try? GTIDSet(completed) {
            // A single configured endpoint estimates the work through that GTID.
            let remaining = done.covers(set) ? 0 : set.remainingTransactions(after: done, throughEndpoints: replay)
            result.remainingTransactions = remaining
            if remaining == 0 {
                result.status = "caughtUp"
                result.estimatedSecondsRemaining = 0
            } else if result.transactionsPerSecond > 0 {
                let rate = result.transactionsPerSecond - (replay ? 0 : sourceRate)
                result.status = rate > 0 ? "estimated" : "notCatchingUp"
                if rate > 0 { result.estimatedSecondsRemaining = Double(remaining) / rate }
            } else if samples.count > 1 && now - (samples.first?.time ?? now) >= 1 {
                result.status = "noRecentProgress"
            }
        } else {
            result.status = replay ? "readingArchiveGoal" : "waitingForSourceSample"
        }
        if ["BLOCKED", "STOPPED", "RECONNECTING", "TARGET_RECONNECTING"].contains(lifecycle),
            result.remainingTransactions != 0
        {
            result.status = "paused"
            result.estimatedSecondsRemaining = nil
        }
        return result
    }
}
