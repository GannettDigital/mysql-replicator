import ReplicatorCapture

/// Target-only work. The caller must first sync relay data and journal every
/// group. A failed BINLOG request never falls back to SQL or another request.
enum BinlogExecution {
    static func run(
        _ groups: [PreparedDMLGroup], transactional: Bool, cancellation: CaptureCancellation,
        skipErrors: SkipErrorPolicy = .init(),
        prepare: (PreparedDMLGroup) throws -> Void, begin: () throws -> Void,
        write: (PreparedDMLGroup) throws -> Void, commit: () throws -> Void,
        rollback: () throws -> Void,
        skippedGTID: (PreparedDMLGroup) throws -> Void,
        resetTrace: () -> Void, trace: () -> TargetStatementTrace
    ) -> DMLExecution.Outcome {
        var counts = Array(repeating: 0, count: groups.count)
        var skipped: [Int: SkippedApplyError] = [:]
        for (index, group) in groups.enumerated() {
            var started = false
            var issued = false
            var committing = false
            do {
                resetTrace()
                try require(!cancellation.isCancelled, "apply cancelled")
                try prepare(group)
                try begin()
                started = true
                try require(!cancellation.isCancelled, "apply cancelled")
                issued = true
                try write(group)
                try require(!cancellation.isCancelled, "apply cancelled")
                committing = true
                try commit()
                counts[index] = group.mutations.count
            } catch {
                let statement = trace()
                var failure: Error = error
                var outcome =
                    committing
                    ? "commitUncertain"
                    : issued && statement.phase != .notIssued ? "possiblyExecuted" : "notStarted"
                if transactional && started && !committing {
                    do {
                        try rollback()
                        outcome = "rolledBack"
                    } catch { outcome = "rollbackUnconfirmed" }
                }
                if outcome == "rolledBack", !cancellation.isCancelled,
                    let skip = skipErrors.match(error, at: .rolledBack)
                {
                    do {
                        try skippedGTID(group)
                        skipped[index] = skip
                        continue
                    } catch { failure = error }
                }
                let rows = groups.enumerated().flatMap { position, item in
                    item.mutations.enumerated().map { ordinal, mutation in
                        TargetFailureDiagnostic.Rows(
                            gtid: item.id,
                            database: mutation.table.database, table: mutation.table.table,
                            firstOrdinal: ordinal, count: 1,
                            disposition: skipped[position] != nil
                                ? "skippedRolledBack"
                                : position < index ? "acknowledged" : position > index ? "notIssued" : outcome)
                    }
                }
                return .init(
                    acknowledged: counts, failure: failure,
                    diagnostic: .init(
                        reason: String(describing: failure), statement: statement,
                        rows: rows, ddlGTID: nil, ddlSQL: nil, transactionOutcome: outcome,
                        targetSQL: (failure as? ApplyError)?.targetSQL),
                    discardUnwritten: failure is TargetConnectionFailure && outcome == "notStarted"
                        && statement.phase == .notIssued,
                    skipped: skipped)
            }
        }
        return .init(acknowledged: counts, failure: nil, skipped: skipped)
    }
}

extension TargetSession {
    func preflightBinlog() throws {
        let variable = (serverVersionID ?? 0) >= 80400 ? "replica_exec_mode" : "slave_exec_mode"
        try require(
            try scalar("SELECT @@GLOBAL.\(variable) AS v") == "STRICT",
            "BINLOG transport requires target \(variable)=STRICT")
        let skips = (serverVersionID ?? 0) >= 80400 ? "replica_skip_errors" : "slave_skip_errors"
        try require(
            try scalar("SELECT @@GLOBAL.\(skips) AS v") == "OFF",
            "BINLOG transport requires target \(skips)=OFF; use the replicator skipErrors policy")
        let pseudo = (serverVersionID ?? 0) >= 80400 ? "pseudo_replica_mode" : "pseudo_slave_mode"
        _ = try query("SET SESSION \(pseudo)=\(config.target.preserveSourceGTIDs ? 1 : 0)", textProtocol: true)
    }

    func executeBinlog(
        _ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
        checkSourceFailure: @escaping () throws -> Void
    ) -> DMLExecution.Outcome {
        BinlogExecution.run(
            groups, transactional: contract.transactional, cancellation: cancellation,
            skipErrors: config.skipErrorPolicy,
            prepare: { item in
                try checkSourceFailure()
                guard let program = item.binlog else { throw ApplyError("missing prepared BINLOG program") }
                try self.checkSourceGTID(item.group.gtid!)
                var seen = Set<SQLNameKey>()
                for mutation in item.mutations where seen.insert(mutation.table.identity).inserted {
                    try self.lock(mutation.table)  // Config validation excludes LOCK TABLES in this mode.
                }
                try self.timings.measure("target.binlog.format") {
                    // A new session must get its own FDE, even if its source file
                    // matches the previous connection. FDE carries no row writes.
                    try self.binlogContext.install(
                        program.format, preserveSourceGTIDs: self.config.target.preserveSourceGTIDs
                    ) { sql in
                        _ = try self.query(sql, textProtocol: true)
                    }
                }
                if self.config.target.preserveSourceGTIDs { try self.assignSourceGTID(item.group.gtid!) }
            }, begin: { _ = try self.query("BEGIN", textProtocol: true) },
            write: { item in
                try checkSourceFailure()
                guard let program = item.binlog else { throw ApplyError("missing prepared BINLOG program") }
                for statement in program.statements {
                    try require(!cancellation.isCancelled, "apply cancelled")
                    try self.timings.measure("target.binlog.rows") {
                        let sql = try self.timings.measure("apply.binlog.base64") { statement.sql() }
                        _ = try self.query(sql, textProtocol: true, mutation: true)
                    }
                }
            }, commit: { _ = try self.query("COMMIT", textProtocol: true, mutation: true) },
            rollback: { _ = try self.query("ROLLBACK", textProtocol: true) },
            skippedGTID: { try self.emptySourceGTID($0.group.gtid!) },
            resetTrace: { self.statementTrace = .init() }, trace: { self.statementTrace })
    }
}
