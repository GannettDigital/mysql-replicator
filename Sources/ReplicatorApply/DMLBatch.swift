import Foundation
import ReplicatorCodec
import ReplicatorCapture

public struct BatchPolicy: Decodable {
    public var maximumTransactions = 32
    public var maximumRows = 4096
    public var maximumWireBytes = 8*1024*1024
    public var maximumDelayMilliseconds = 25
    public init() {}
    enum CodingKeys: String, CodingKey { case maximumTransactions,maximumRows,maximumWireBytes,maximumDelayMilliseconds }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        maximumTransactions = try c.decodeIfPresent(Int.self,forKey:.maximumTransactions) ?? maximumTransactions
        maximumRows = try c.decodeIfPresent(Int.self,forKey:.maximumRows) ?? maximumRows
        maximumWireBytes = try c.decodeIfPresent(Int.self,forKey:.maximumWireBytes) ?? maximumWireBytes
        maximumDelayMilliseconds = try c.decodeIfPresent(Int.self,forKey:.maximumDelayMilliseconds) ?? maximumDelayMilliseconds
    }
    func validate() throws {
        try require((1...256).contains(maximumTransactions) && (1...65536).contains(maximumRows)
            && (1024...32*1024*1024).contains(maximumWireBytes) && (1...1000).contains(maximumDelayMilliseconds),"invalid DML batch limits")
    }
}

struct PreparedDMLGroup {
    let group: CompleteTransaction
    let mutations: [Mutation]
    let relayEnd: UInt64
    var id: String { group.gtid!.sid+":"+group.gtid!.sequence }
    var wireBytes: Int { group.events.reduce(0) { $0+Int($1.eventSize) } }
}

/// Serial capture-consumer buffer. Bounds are checked at complete-group/event
/// boundaries. A group exceeding a collection limit runs alone; it is never split.
final class DMLBatch {
    /// The injected target operations keep fault tests on the actual journal /
    /// acknowledgment path, without requiring a running MySQL server.
    static func execute(_ groups: [PreparedDMLGroup], state: StateStore, cancellation: CaptureCancellation,
                        lock: (ApplyTable) throws -> Void, write: (Mutation) throws -> Void,
                        completedGroup: () throws -> Void) throws {
        try require(!groups.isEmpty && groups.allSatisfy{ !$0.mutations.isEmpty },"empty DML batch or group")
        try lock(groups[0].mutations[0].table)
        try state.beginBatch(groups)
        var acknowledged = Array(repeating:0,count:groups.count)
        do {
            for (index,item) in groups.enumerated() {
                if index > 0 { try lock(item.mutations[0].table) }
                for mutation in item.mutations {
                    try require(!cancellation.isCancelled,"apply cancelled")
                    try write(mutation)
                    acknowledged[index]+=1
                }
                if index != groups.count-1 { try completedGroup() }
            }
        } catch {
            do { try state.finishBatch(acknowledgedRows:acknowledged) }
            catch let journalError { throw ApplyError("\(error); additionally failed to record batch prefix: \(journalError)") }
            throw error
        }
        // Commit errors do not reenter the failure-prefix path or retry SQL.
        try state.finishBatch(acknowledgedRows:acknowledged)
        try completedGroup()
    }
    private var groups: [PreparedDMLGroup] = []
    private var rows = 0, bytes = 0
    private var started = 0.0
    private var failed = false
    private let policy: BatchPolicy
    private let uptime: () -> Double
    private let apply: ([PreparedDMLGroup]) throws -> Void
    init(policy: BatchPolicy, uptime: @escaping () -> Double = {ProcessInfo.processInfo.systemUptime},
         apply: @escaping ([PreparedDMLGroup]) throws -> Void) {
        self.policy=policy; self.uptime=uptime; self.apply=apply
    }
    func append(_ group: PreparedDMLGroup) throws {
        try require(!failed && !group.mutations.isEmpty,"cannot append to failed or empty DML batch")
        try flushIfExpired()
        let cost = group.wireBytes
        if !groups.isEmpty && (groups[0].mutations[0].table != group.mutations[0].table
            || rows+group.mutations.count > policy.maximumRows || bytes+cost > policy.maximumWireBytes) { try flush() }
        if groups.isEmpty { started=uptime() }
        groups.append(group); rows+=group.mutations.count; bytes+=cost
        if groups.count >= policy.maximumTransactions || rows >= policy.maximumRows || bytes >= policy.maximumWireBytes { try flush() }
    }
    func flushIfExpired() throws {
        if !groups.isEmpty && uptime()-started >= Double(policy.maximumDelayMilliseconds)/1000 { try flush() }
    }
    func flush() throws {
        try require(!failed,"DML batch already failed; retry is forbidden")
        guard !groups.isEmpty else { return }
        let pending=groups
        groups=[]; rows=0; bytes=0
        do { try apply(pending) }
        catch { failed=true; throw error }
    }
}
