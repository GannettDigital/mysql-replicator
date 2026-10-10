import Foundation
import ReplicatorCapture

/// Target-only execution. The coordinator has already journaled all intents.
/// An unsuccessful combined statement acknowledges NONE of its rows, even if
/// MyISAM wrote a prefix. Source group identities remain separate in the journal.
struct DMLExecution {
    struct Outcome {
        let acknowledged: [Int]
        let failure: Error?
        var diagnostic: TargetFailureDiagnostic? = nil
        var discardUnwritten = false
        var skipped: [Int:SkippedApplyError] = [:]
        func record(in state: StateStore) throws {
            do {
                try state.finishBatch(acknowledgedRows:acknowledged,skipped:skipped)
                if let diagnostic { try state.recordTargetFailure(diagnostic) }
                if discardUnwritten { try state.discardUnwrittenPending() }
            }
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
                    insert: ([Mutation]) throws -> Void, completedGroup: () throws -> Void,
                    resetTrace: () -> Void = {}, trace: () -> TargetStatementTrace = { .init(phase:.possiblyExecuted) }) -> Outcome {
        var acknowledged = Array(repeating:0,count:groups.count)
        // Each reference retains its original group and row ordinal. Chunking
        // never changes row order or moves work across a table/operation boundary.
        let rows = groups.enumerated().flatMap { index,group in group.mutations.map { (index,$0) } }
        var cursor = 0, attemptedEnd = 0
        do {
            while cursor < rows.count {
                resetTrace()
                attemptedEnd = cursor
                try require(!cancellation.isCancelled,"apply cancelled")
                let first = rows[cursor].1
                let count = insertChunkCount(first,maximumInsertRows:maximumInsertRows,maximumInsertBytes:maximumInsertBytes) { offset in
                        let end = cursor+offset
                        guard end < rows.count else { return nil }
                        // Coalesce across source groups only when both groups
                        // contain one row. With explicit locks enabled, larger
                        // groups keep their lock until their last chunk.
                        if rows[end].0 != rows[cursor].0 && (groups[rows[cursor].0].mutations.count != 1 || groups[rows[end].0].mutations.count != 1) { return nil }
                        return rows[end].1
                }
                let end = cursor+count
                attemptedEnd = end
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
        } catch {
            let statement = trace()
            var spans: [TargetFailureDiagnostic.Rows] = []
            for (groupIndex, group) in groups.enumerated() {
                var ordinal = 0
                while ordinal < group.mutations.count {
                    let absolute = groups.prefix(groupIndex).reduce(0) { $0 + $1.mutations.count } + ordinal
                    let disposition: String
                    let end: Int
                    if ordinal < acknowledged[groupIndex] {
                        disposition = "acknowledged"; end = acknowledged[groupIndex]
                    } else if absolute >= cursor && absolute < attemptedEnd && statement.phase != .notIssued {
                        disposition = "possiblyExecuted"; end = min(group.mutations.count, ordinal + attemptedEnd-absolute)
                    } else {
                        disposition = "notIssued"; end = group.mutations.count
                    }
                    let table = group.mutations[ordinal].table
                    spans.append(.init(gtid:group.id,database:table.database,table:table.table,
                                       firstOrdinal:ordinal,count:end-ordinal,disposition:disposition))
                    ordinal = end
                }
            }
            // Only whole, entirely unissued groups can be downloaded again.
            // A partially acknowledged group remains blocked, even on read failure.
            let wholeGroups = zip(groups,acknowledged).allSatisfy { $1 == 0 || $1 == $0.mutations.count }
            return Outcome(acknowledged:acknowledged,failure:error,
                diagnostic:.init(reason:String(describing:error),statement:statement,rows:spans,ddlGTID:nil,ddlSQL:nil),
                discardUnwritten:error is TargetConnectionFailure && statement.phase == .notIssued && wholeGroups)
        }
    }

    /// Count target writes, not source SQL statements. UPDATE/DELETE image checks
    /// precede the write under our exclusive-writer contract. Generated-column
    /// checks follow the write and must remain rollbackable.
    static func canAutocommit(_ group: PreparedDMLGroup, maximumInsertRows: Int, maximumInsertBytes: Int) -> Bool {
        guard let first = group.mutations.first else { return false }
        if first.row.operation == "delete" { return group.mutations.count == 1 }
        guard !first.table.columns.contains(where: { $0.isGenerated }) else { return false }
        if first.row.operation == "update" { return group.mutations.count == 1 }
        guard first.row.operation == "insert" else { return false }
        return insertChunkCount(first,maximumInsertRows:maximumInsertRows,maximumInsertBytes:maximumInsertBytes) { offset in
            offset < group.mutations.count ? group.mutations[offset] : nil
        } == group.mutations.count
    }

    private static func insertChunkCount(_ first: Mutation, maximumInsertRows: Int, maximumInsertBytes: Int,
                                         next: (Int) -> Mutation?) -> Int {
        guard first.row.operation == "insert" else { return 1 }
        var count = 1, bytes = insertBytes(first)
        while count < maximumInsertRows, let mutation = next(count) {
            let cost = insertBytes(mutation)
            guard mutation.row.operation == "insert", mutation.table == first.table,
                  bytes <= maximumInsertBytes-cost else { break }
            bytes += cost; count += 1
        }
        // Powers of two bound prepared statement shapes per table.
        var size = 1
        while size*2 <= count { size *= 2 }
        return size
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
