import ReplicatorCapture

/// Acknowledges only committed source transactions. Successful row statements
/// are provisional until COMMIT; never expose them as a durable prefix.
enum InnoDBExecution {
    static func run(_ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
                    maximumInsertRows: Int, maximumInsertBytes: Int,
                    prepare: (PreparedDMLGroup) throws -> Void = { _ in },
                    skipErrors: SkipErrorPolicy = .init(),
                    begin: () throws -> Void, commit: () throws -> Void, rollback: () throws -> Void,
                    write: (Mutation) throws -> Void, insert: ([Mutation]) throws -> Void,
                    resetTrace: () -> Void, trace: () -> TargetStatementTrace) -> DMLExecution.Outcome {
        var acknowledged = Array(repeating:0,count:groups.count)
        var skipped: [Int:SkippedApplyError] = [:]
        for (index,group) in groups.enumerated() {
            var started = false, committing = false
            do {
                resetTrace()
                try require(!cancellation.isCancelled,"apply cancelled")
                try prepare(group)
                try begin(); started = true
                let result = DMLExecution.run([group],cancellation:cancellation,
                    maximumInsertRows:maximumInsertRows,maximumInsertBytes:maximumInsertBytes,
                    lock:{ _ in },write:write,insert:insert,completedGroup:{},
                    resetTrace:resetTrace,trace:trace)
                if let failure = result.failure { throw failure }
                try require(!cancellation.isCancelled,"apply cancelled")
                committing = true
                try commit()
                acknowledged[index] = group.mutations.count
            } catch {
                let failedTrace = trace()
                var outcome = committing ? "commitUncertain" : "notStarted"
                if started && !committing {
                    do { try rollback(); outcome = "rolledBack" }
                    catch { outcome = "rollbackUnconfirmed" }
                }
                if outcome == "rolledBack",let skip=skipErrors.match(error,at:.rolledBack), !cancellation.isCancelled {
                    skipped[index]=skip
                    continue
                }
                // BEGIN's lost response cannot have applied row mutations.
                // Do not label uncommitted successful statements acknowledged.
                let diagnostic = TargetFailureDiagnostic(reason:String(describing:error),statement:failedTrace,
                    rows:diagnosticRows(groups,failedIndex:index,outcome:outcome,skipped:skipped),
                    ddlGTID:nil,ddlSQL:nil,transactionOutcome:outcome)
                return .init(acknowledged:acknowledged,failure:error,diagnostic:diagnostic,skipped:skipped)
            }
        }
        return .init(acknowledged:acknowledged,failure:nil,skipped:skipped)
    }

    private static func diagnosticRows(_ groups: [PreparedDMLGroup], failedIndex: Int,
                                       outcome: String, skipped: [Int:SkippedApplyError]) -> [TargetFailureDiagnostic.Rows] {
        var result: [TargetFailureDiagnostic.Rows] = []
        for (index,group) in groups.enumerated() {
            var first = 0
            while first < group.mutations.count {
                let table = group.mutations[first].table
                var end = first+1
                while end < group.mutations.count && group.mutations[end].table.identity == table.identity { end += 1 }
                result.append(.init(gtid:group.id,database:table.database,table:table.table,firstOrdinal:first,count:end-first,
                    disposition:skipped[index] != nil ? "skippedRolledBack" : index < failedIndex ? "acknowledged" : index > failedIndex ? "notIssued" : outcome))
                first = end
            }
        }
        return result
    }
}
