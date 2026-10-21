import Foundation
import ReplicatorCodec

/// Live work is separate from the coordinator's published checkpoint. A status
/// request copies this small record. It never calls a worker, SQLite, or MySQL.
public struct RunActivitySnapshot: Encodable {
    public struct Phase: Encodable {
        public let name: String
        public let elapsedSeconds: Double
        public let database: String?
        public let table: String?
        public let purpose: String?
    }
    public let generatedAt: Double
    public let checkpointUpdatedAt: Double?
    public let checkpointAgeSeconds: Double?
    public let lastProgressAt: Double?
    public let secondsSinceLastProgress: Double?
    public internal(set) var phases: [String: Phase]
    public let readPosition: BinlogCoordinate?
    public let preparedPosition: BinlogCoordinate?
}

final class RunActivity: @unchecked Sendable {
    enum Worker: String { case coordinator, capture, target }
    private struct Phase {
        let name: String
        let start: Double
        let database: String?
        let table: String?
        let purpose: String?
    }
    private let lock = NSLock()
    private let uptime: () -> Double
    private let wallTime: () -> Double
    private var phases: [Worker: [Phase]] = [:]
    private var published: (wall: Double, time: Double)?
    private var progressed: (wall: Double, time: Double)?
    private var transactions: Int?
    private var read: BinlogCoordinate?
    private var prepared: BinlogCoordinate?
    init(
        uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallTime: @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.uptime = uptime
        self.wallTime = wallTime
    }
    // Each worker nests and ends its own scopes in order. Locks cover only record
    // changes, never the body of a query or archive scan.
    func begin(_ worker: Worker, _ name: String, table: TableName? = nil, purpose: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        phases[worker, default: []].append(
            Phase(name: name, start: uptime(), database: table?.database, table: table?.table, purpose: purpose))
    }
    func end(_ worker: Worker) {
        lock.lock()
        defer { lock.unlock() }
        _ = phases[worker]?.popLast()
    }
    func measure<T>(_ worker: Worker, _ name: String, _ body: () throws -> T) rethrows -> T {
        begin(worker, name)
        defer { end(worker) }
        return try body()
    }
    func checkpoint(transactions: Int) {
        lock.lock()
        defer { lock.unlock() }
        let time = (wall: wallTime(), time: uptime())
        published = time
        if let prior = self.transactions, transactions > prior { progressed = time }
        self.transactions = transactions
    }
    func didRead(_ position: BinlogCoordinate) {
        lock.lock()
        defer { lock.unlock() }
        read = position
    }
    func didPrepare(_ position: BinlogCoordinate) {
        lock.lock()
        defer { lock.unlock() }
        prepared = position
    }
    func resetPositions(to applied: BinlogCoordinate?) {
        lock.lock()
        defer { lock.unlock() }
        read = applied
        prepared = applied
    }
    var snapshot: RunActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = uptime()
        let current = phases.reduce(into: [String: RunActivitySnapshot.Phase]()) { result, item in
            guard let phase = item.value.last else { return }
            result[item.key.rawValue] = .init(
                name: phase.name, elapsedSeconds: max(0, now - phase.start),
                database: phase.database, table: phase.table, purpose: phase.purpose)
        }
        return RunActivitySnapshot(
            generatedAt: wallTime(), checkpointUpdatedAt: published?.wall,
            checkpointAgeSeconds: published.map { max(0, now - $0.time) },
            lastProgressAt: progressed?.wall, secondsSinceLastProgress: progressed.map { max(0, now - $0.time) },
            phases: current, readPosition: read, preparedPosition: prepared)
    }
}

extension ApplySummary {
    func refreshingActivity(from activity: RunActivity) -> ApplySummary {
        var value = self
        value.activity = activity.snapshot
        if ["BLOCKED", "STOPPED"].contains(lifecycle) { value.activity?.phases = [:] }
        if let age = value.activity?.checkpointAgeSeconds, var estimate = value.estimate {
            estimate.sampleAgeSeconds = age
            if let observedAge = estimate.sourceObservationAgeSeconds {
                estimate.sourceObservationAgeSeconds = observedAge + age
                if observedAge + age > Double(estimate.sourceObservationStaleAfterSeconds) {
                    estimate.sourceObservationStale = true
                    estimate.provisional = true
                    if estimate.status != "paused" { estimate.status = "staleSourceSample" }
                }
            }
            if age > Double(estimate.rateWindowSeconds) {
                estimate.provisional = true
                if estimate.status == "estimated" { estimate.status = "staleRateSample" }
            }
            value.estimate = estimate
        }
        return value
    }
}
