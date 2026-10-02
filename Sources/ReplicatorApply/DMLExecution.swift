import Foundation
import ReplicatorCapture

/// Target-only execution. The coordinator has already journaled all intents.
/// An unsuccessful combined statement acknowledges NONE of its rows, even if
/// MyISAM wrote a prefix. Source group identities remain separate in the journal.
struct DMLExecution {
    struct Outcome {
        let acknowledged: [Int]
        let failure: Error?
        func record(in state: StateStore) throws {
            do { try state.finishBatch(acknowledgedRows:acknowledged) }
            catch {
                if let failure { throw ApplyError("\(failure); additionally failed to record batch prefix: \(error)") }
                throw error
            }
            if let failure { throw failure }
        }
    }
    static func run(_ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
                    maximumInsertRows: Int, maximumInsertBytes: Int,
                    lock: (ApplyTable) throws -> Void, write: (Mutation) throws -> Void,
                    insert: ([Mutation]) throws -> Void, completedGroup: () throws -> Void) -> Outcome {
        var acknowledged = Array(repeating:0,count:groups.count)
        // Each reference retains its original group and row ordinal. Chunking
        // never changes row order or moves work across a table/operation boundary.
        let rows = groups.enumerated().flatMap { index,group in group.mutations.map { (index,$0) } }
        var cursor = 0
        do {
            while cursor < rows.count {
                try require(!cancellation.isCancelled,"apply cancelled")
                let first = rows[cursor].1
                var end = cursor+1, bytes = insertBytes(first)
                if first.row.operation == "insert" {
                    while end < rows.count && end-cursor < maximumInsertRows {
                        let next = rows[end].1, cost = insertBytes(next)
                        // Coalesce across source groups only when both groups
                        // contain one row. With explicit locks enabled, larger
                        // groups keep their lock until their last chunk.
                        if rows[end].0 != rows[cursor].0 && (groups[rows[cursor].0].mutations.count != 1 || groups[rows[end].0].mutations.count != 1) { break }
                        guard next.row.operation == "insert", next.table == first.table,
                              bytes <= maximumInsertBytes-cost else { break }
                        bytes += cost; end += 1
                    }
                    // Powers of two bound prepared statement shapes per table.
                    var size = 1
                    while size*2 <= end-cursor { size *= 2 }
                    end = cursor+size
                }
                if acknowledged[rows[cursor].0] == 0 { try lock(first.table) }
                if end-cursor == 1 { try write(first) }
                else { try insert(rows[cursor..<end].map { $0.1 }) }
                // First record all successful rows in memory. Lock release can
                // fail afterwards without losing a known successful response.
                var completed = 0
                for index in cursor..<end {
                    let group = rows[index].0
                    acknowledged[group] += 1
                    if acknowledged[group] == groups[group].mutations.count { completed += 1 }
                }
                for _ in 0..<completed { try completedGroup() }
                cursor = end
            }
            return Outcome(acknowledged:acknowledged,failure:nil)
        } catch { return Outcome(acknowledged:acknowledged,failure:error) }
    }

    /// Conservative bound for both prepare SQL and execute parameters. Count
    /// the escaped identifier prefix per row too: deliberately overestimates it.
    static func insertBytes(_ mutation: Mutation) -> Int {
        let identifiers = [mutation.table.database,mutation.table.table] + mutation.table.columns.map(\.name)
        let prefix = identifiers.reduce(64) { $0 + $1.utf8.count*2 + 4 }
        return (mutation.row.after ?? []).reduce(prefix) { sum,value in
            switch value {
            case .text(let s), .decimal(let s), .temporal(let s): return sum+s.utf8.count+16
            case .binary(let d): return sum+d.count+16
            default: return sum+24
            }
        }
    }
}

/// At most one target batch executes while the coordinator collects the next
/// bounded batch. No StateStore access occurs on this queue. join() is mandatory
/// before touching the target session, checkpointing or reporting its timings.
final class DMLExecutor {
    private let queue = DispatchQueue(label:"mysql-replicator.target")
    private let done = DispatchGroup()
    private var outcome: DMLExecution.Outcome?
    private(set) var active = false
    var ready: Bool { active && done.wait(timeout:.now()) == .success }
    func start(_ work: @escaping () -> DMLExecution.Outcome) {
        precondition(!active)
        active = true; done.enter()
        queue.async {
            self.outcome = work()
            self.done.leave()
        }
    }
    func join() -> DMLExecution.Outcome? {
        guard active else { return nil }
        done.wait()
        active = false
        let result = outcome; outcome = nil
        return result
    }
    deinit { done.wait() }
}
