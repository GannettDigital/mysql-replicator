import Foundation
import ReplicatorCodec
import ReplicatorCapture

public struct BatchPolicy: Decodable {
    public var maximumInsertRows = 32
    public var maximumInsertBytes = 1024*1024
    public var overlapPreparation = true
    public var flushOnTableChange = false
    public var maximumTransactions = 32
    public var maximumRows = 4096
    public var maximumWireBytes = 8*1024*1024
    public var maximumDelayMilliseconds = 25
    public init() {}
    enum CodingKeys: String, CodingKey { case maximumInsertRows,maximumInsertBytes,overlapPreparation,flushOnTableChange,maximumTransactions,maximumRows,maximumWireBytes,maximumDelayMilliseconds }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        maximumInsertRows = try c.decodeIfPresent(Int.self,forKey:.maximumInsertRows) ?? maximumInsertRows
        maximumInsertBytes = try c.decodeIfPresent(Int.self,forKey:.maximumInsertBytes) ?? maximumInsertBytes
        overlapPreparation = try c.decodeIfPresent(Bool.self,forKey:.overlapPreparation) ?? overlapPreparation
        flushOnTableChange = try c.decodeIfPresent(Bool.self,forKey:.flushOnTableChange) ?? flushOnTableChange
        maximumTransactions = try c.decodeIfPresent(Int.self,forKey:.maximumTransactions) ?? maximumTransactions
        maximumRows = try c.decodeIfPresent(Int.self,forKey:.maximumRows) ?? maximumRows
        maximumWireBytes = try c.decodeIfPresent(Int.self,forKey:.maximumWireBytes) ?? maximumWireBytes
        maximumDelayMilliseconds = try c.decodeIfPresent(Int.self,forKey:.maximumDelayMilliseconds) ?? maximumDelayMilliseconds
    }
    func validate() throws {
        try require((1...128).contains(maximumInsertRows) && (1024...4*1024*1024).contains(maximumInsertBytes),"invalid multi-row INSERT limits")
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
                        maximumInsertRows: Int = 1, maximumInsertBytes: Int = 1024*1024,
                        lock: (ApplyTable) throws -> Void, write: (Mutation) throws -> Void,
                        insert: (([Mutation]) throws -> Void)? = nil,
                        completedGroup: () throws -> Void) throws {
        try require(!groups.isEmpty && groups.allSatisfy{ !$0.mutations.isEmpty },"empty DML batch or group")
        try lock(groups[0].mutations[0].table)
        try state.beginBatch(groups)
        let outcome = DMLExecution.run(groups,cancellation:cancellation,
            maximumInsertRows:insert == nil ? 1 : maximumInsertRows,maximumInsertBytes:maximumInsertBytes,
            lock:lock,write:write,insert:insert ?? { _ in throw ApplyError("missing INSERT writer") },completedGroup:completedGroup)
        try outcome.record(in:state)
    }
    private var groups: [PreparedDMLGroup] = []
    private var rows = 0, bytes = 0
    private var started = 0.0
    private var failed = false
    private let policy: BatchPolicy
    private let uptime: () -> Double
    private let onFlush: (String) -> Void
    private let apply: ([PreparedDMLGroup]) throws -> Void
    init(policy: BatchPolicy, uptime: @escaping () -> Double = {ProcessInfo.processInfo.systemUptime},
         onFlush: @escaping (String) -> Void = { _ in }, apply: @escaping ([PreparedDMLGroup]) throws -> Void) {
        self.policy=policy; self.uptime=uptime; self.onFlush=onFlush; self.apply=apply
    }
    func append(_ group: PreparedDMLGroup) throws {
        try require(!failed && !group.mutations.isEmpty,"cannot append to failed or empty DML batch")
        try flushIfExpired()
        let cost = group.wireBytes
        if !groups.isEmpty {
            if policy.flushOnTableChange && groups[0].mutations[0].table != group.mutations[0].table { try flush(reason:"table") }
            else if rows+group.mutations.count > policy.maximumRows { try flush(reason:"rows") }
            else if bytes+cost > policy.maximumWireBytes { try flush(reason:"bytes") }
        }
        if groups.isEmpty { started=uptime() }
        groups.append(group); rows+=group.mutations.count; bytes+=cost
        if groups.count >= policy.maximumTransactions { try flush(reason:"transactions") }
        else if rows >= policy.maximumRows { try flush(reason:"rows") }
        else if bytes >= policy.maximumWireBytes { try flush(reason:"bytes") }
    }
    func flushIfExpired() throws {
        if !groups.isEmpty && uptime()-started >= Double(policy.maximumDelayMilliseconds)/1000 { try flush(reason:"age") }
    }
    /// Only unjournaled preparation is discarded. The coordinator joins any
    /// active executor and checks durable pending intents before reconnecting.
    func discard() {
        groups=[]; rows=0; bytes=0; started=0
    }
    func flush(reason: String = "explicit") throws {
        try require(!failed,"DML batch already failed; retry is forbidden")
        guard !groups.isEmpty else { return }
        onFlush(reason)
        let pending=groups
        groups=[]; rows=0; bytes=0
        do { try apply(pending) }
        catch { failed=true; throw error }
    }
}
