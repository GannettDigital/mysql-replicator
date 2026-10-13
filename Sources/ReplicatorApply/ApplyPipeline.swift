import Foundation
import ReplicatorCapture
import ReplicatorCodec

public struct PipelineSnapshot: Encodable {
    public var queuedItems = 0
    public var queuedGroups = 0
    public var queuedBytes = 0
    public var maximumItems = 0
    public var maximumGroups = 0
    public var maximumBytes = 0
    public var groupsEnqueued = 0
    public var groupsDequeued = 0
}

/// One producer and one consumer. Failure discards unconsumed work, success
/// drains it. No callback executes with the mutex held. Costs are retained-data
/// accounting (including duplicated group/event references), not an RSS bound.
final class ApplyQueue<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [(Element, Int, Int)?] = []
    private var head = 0
    private var ended = false
    private var failure: Error?
    private var counters = PipelineSnapshot()
    let byteLimit: Int, itemLimit: Int, groupLimit: Int
    init(byteLimit: Int = 64*1024*1024, itemLimit: Int = 4096, groupLimit: Int = 64) {
        self.byteLimit = byteLimit; self.itemLimit = itemLimit; self.groupLimit = groupLimit
    }
    var snapshot: PipelineSnapshot {
        condition.lock(); defer { condition.unlock() }; return counters
    }
    func checkFailure(allowSourceReconnect: Bool = false, allowDrain: Bool = false) throws {
        condition.lock(); defer { condition.unlock() }
        if let failure {
            if allowDrain && (failure is ApplyDrainRequested || failure is ApplyReloadRequested) { return }
            // A source-only interruption cannot cancel already-journaled SQL.
            // The consumer still receives the failure and discards queued work.
            if allowSourceReconnect, let live = failure as? LiveInspectionError, live.isRetryableSourceFailure { return }
            throw failure
        }
    }
    func push(_ item: Element, bytes: Int, groups: Int = 0, cancellation: CaptureCancellation) throws {
        try require(bytes >= 0 && bytes <= byteLimit && (0...1).contains(groups),"decoded queue item exceeds capacity")
        condition.lock(); defer { condition.unlock() }
        while true {
            if let failure { throw failure }
            if cancellation.isCancelled { throw CaptureCancelled() }
            try require(!ended,"decoded queue already finished")
            if counters.queuedItems < itemLimit && counters.queuedBytes <= byteLimit-bytes
                && counters.queuedGroups+groups <= groupLimit { break }
            _ = condition.wait(until:Date().addingTimeInterval(0.05))
        }
        items.append((item,bytes,groups))
        counters.queuedItems += 1; counters.queuedBytes += bytes; counters.queuedGroups += groups
        counters.groupsEnqueued += groups
        counters.maximumItems = max(counters.maximumItems,counters.queuedItems)
        counters.maximumBytes = max(counters.maximumBytes,counters.queuedBytes)
        counters.maximumGroups = max(counters.maximumGroups,counters.queuedGroups)
        condition.signal()
    }
    func finish(_ result: Result<Void,Error>) {
        condition.lock(); defer { condition.unlock() }
        ended = true
        if case .failure(let error) = result,
           failure == nil || ((failure as? LiveInspectionError)?.isRetryableSourceFailure == true
                             && (error as? LiveInspectionError)?.isRetryableSourceFailure != true) {
            // A fatal consumer failure supersedes a recoverable source outage.
            failure = error; items = []; head = 0
            counters.queuedItems = 0; counters.queuedBytes = 0; counters.queuedGroups = 0
        }
        condition.broadcast()
    }
    func next(onWait: () throws -> Void) throws -> Element? {
        condition.lock(); defer { condition.unlock() }
        while true {
            if let failure { throw failure }
            if head < items.count {
                let (item,bytes,groups) = items[head]!
                items[head] = nil; head += 1
                counters.queuedItems -= 1; counters.queuedBytes -= bytes; counters.queuedGroups -= groups
                counters.groupsDequeued += groups
                if head == items.count { items = []; head = 0 }
                else if head >= 1024 { items.removeFirst(head); head = 0 }
                condition.signal(); return item
            }
            if ended { return nil }
            _ = condition.wait(until:Date().addingTimeInterval(0.025))
            condition.unlock()
            do { try onWait() } catch { condition.lock(); throw error }
            condition.lock()
        }
    }
}

/// The decoder waits only on schema barriers. The consumer owns target access;
/// cancellation must release a producer waiting after a consumer-side failure.
final class ApplySchemaRequest {
    let event: DecodedEvent
    private let condition = NSCondition()
    private var result: Result<[ColumnInterpretation],Error>?
    init(_ event: DecodedEvent) { self.event = event }
    func complete(_ result: Result<[ColumnInterpretation],Error>) {
        condition.lock(); defer { condition.unlock() }
        self.result = result; condition.broadcast()
    }
    func wait(cancellation: CaptureCancellation) throws -> [ColumnInterpretation] {
        condition.lock(); defer { condition.unlock() }
        while result == nil {
            if cancellation.isCancelled { throw CaptureCancelled() }
            _ = condition.wait(until:Date().addingTimeInterval(0.05))
        }
        return try result!.get()
    }
}

enum ApplyMessage {
    case event(LiveRecord)
    case transaction(CompleteTransaction)
    case schema(ApplySchemaRequest)
    case idle
    var cost: Int {
        switch self {
        case .event(let record): return 256 + (record.event?.retainedByteCost ?? record.rawBase64?.utf8.count ?? 0) + (record.rawBytes?.count ?? 0)
        case .transaction(let group): return 1024 + group.events.reduce(0) { $0 + $1.retainedByteCost }
        case .schema(let request): return 256 + request.event.retainedByteCost
        case .idle: return 1
        }
    }
    var groups: Int { if case .transaction = self { return 1 }; return 0 }
}

/// Capture/decoding/assembly run on the producer. The consumer owns relay,
/// SQLite and DML preparation, and may dispatch one durable batch to a separate
/// target executor. Modern wire metadata determines decode types; legacy maps
/// request a schema interpretation from the consumer at an ordered barrier.
/// Schema validation and durable intents precede any writes.
final class ApplyPipeline {
    let queue = ApplyQueue<ApplyMessage>()
    func run(cancellation: CaptureCancellation, producerTimings: StageTimings,
             produce: @escaping (CaptureCancellation, @escaping (ApplyMessage) throws -> Void) throws -> Void,
             consume: (ApplyMessage) throws -> Void, onWait: () throws -> Void,
             timings: StageTimings) throws {
        let stop = CaptureCancellation(parent:cancellation)
        let worker = DispatchGroup()
        worker.enter()
        DispatchQueue(label:"mysql-replicator.decode").async { [queue] in
            defer { worker.leave() }
            do {
                try produce(stop) { message in
                    try producerTimings.measure("pipeline.enqueue") {
                        try queue.push(message,bytes:message.cost,groups:message.groups,cancellation:stop)
                    }
                }
                queue.finish(.success(()))
            } catch { queue.finish(.failure(error)) }
        }
        // Joining is mandatory before reading producer timings or destroying any
        // captured objects, even if the target, journal or output callback fails.
        defer { stop.cancel(); worker.wait() }
        do {
            while let message = try timings.measure("pipeline.wait", { try queue.next(onWait:onWait) }) {
                try consume(message)
            }
        } catch {
            queue.finish(.failure(error)); stop.cancel()
            // A concurrent source failure must not mask a target/journal error.
            throw error
        }
    }
}
