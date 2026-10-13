import Foundation

/// Current target-session measurements. Span starts at the first batch and ends
/// at the last completed batch; it excludes process startup and final shutdown.
public struct ApplyQueueSnapshot: Encodable {
    public let capacity: Int
    public let maximumOutstandingBatches: Int
    public let batchesEnqueued: Int
    public let batchesExecuted: Int
    public let batchesNotIssued: Int
    public let busySeconds: Double
    public let idleSeconds: Double
    public let spanSeconds: Double
}

/// One serial target worker, bounded durable submissions, ordered completions.
/// The coordinator alone owns tickets and SQLite. Worker outcomes are published
/// by each ticket's DispatchGroup; the lock protects stop state and statistics.
final class DMLExecutor {
    private final class Ticket {
        let done = DispatchGroup()
        var outcome: DMLExecution.Outcome?
        init() { done.enter() }
    }
    let capacity: Int
    private let queue = DispatchQueue(label:"mysql-replicator.target")
    private var tickets: [Ticket] = []
    private let lock = NSLock()
    private var stopped = false
    private var enqueued = 0, executed = 0, notIssued = 0, maximumOutstanding = 0
    private var busy: UInt64 = 0, idle: UInt64 = 0
    private var lastCompletion: UInt64?

    init(capacity: Int = 1) {
        precondition((1...16).contains(capacity))
        self.capacity=capacity
    }
    var active: Bool { !tickets.isEmpty }
    var available: Int { capacity-tickets.count }
    var full: Bool { available == 0 }
    var failed: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    var ready: Bool { tickets.first.map { $0.done.wait(timeout:.now()) == .success } ?? false }
    var snapshot: ApplyQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(capacity:capacity,maximumOutstandingBatches:maximumOutstanding,
                     batchesEnqueued:enqueued,batchesExecuted:executed,batchesNotIssued:notIssued,
                     busySeconds:Double(busy)/1e9,idleSeconds:Double(idle)/1e9,spanSeconds:Double(busy+idle)/1e9)
    }
    func start(_ work: @escaping () -> DMLExecution.Outcome) {
        precondition(!full)
        let ticket=Ticket()
        tickets.append(ticket)
        lock.lock()
        enqueued += 1; maximumOutstanding=max(maximumOutstanding,tickets.count)
        lock.unlock()
        queue.async {
            let start=DispatchTime.now().uptimeNanoseconds
            self.lock.lock()
            let run = !self.stopped
            if run {
                self.executed += 1
                if let end=self.lastCompletion { self.idle += start-end }
            } else { self.notIssued += 1 }
            self.lock.unlock()
            if run {
                ticket.outcome=work()
                let end=DispatchTime.now().uptimeNanoseconds
                self.lock.lock()
                self.busy += end-start; self.lastCompletion=end
                // Set before publishing completion or starting the next ticket.
                if ticket.outcome?.failure != nil { self.stopped=true }
                self.lock.unlock()
            }
            ticket.done.leave()
        }
    }
    /// A nil result with an outstanding ticket means prior failure prevented its
    /// execution. Its durable intents stay pending; it must never be acknowledged.
    func join() -> DMLExecution.Outcome? {
        guard let ticket=tickets.first else { return nil }
        ticket.done.wait()
        tickets.removeFirst()
        return ticket.outcome
    }
    func cancelAndWait() {
        lock.lock(); stopped=true; lock.unlock()
        while active { _ = join() }
    }
    deinit { cancelAndWait() }
}
