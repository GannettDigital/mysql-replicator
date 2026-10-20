import ReplicatorCapture

extension TargetSession {
    /// Engine-specific transaction semantics stay behind the target adapter;
    /// collection, durable intents and completion remain shared orchestration.
    func execute(
        _ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
        maximumInsertBytes: Int, checkSourceFailure: @escaping () throws -> Void
    ) -> DMLExecution.Outcome {
        let transport = groups.first?.executionTransport() ?? .sql
        dmlTransport = transport
        defer { dmlTransport = nil }
        do {
            try require(
                !groups.isEmpty && groups.allSatisfy { $0.executionTransport() == transport },
                "mixed or empty target transport batch")
            if transport == .binlog {
                try require(config.target.transport == .binlog, "BINLOG program in SQL configuration")
                return executeBinlog(groups, cancellation: cancellation, checkSourceFailure: checkSourceFailure)
            }
            if config.target.transport == .binlog {
                try require(groups.allSatisfy { $0.sqlReason != nil }, "SQL group lacks a compatibility decision")
                statementTrace = .init()
                try checkSourceFailure()
                try require(!cancellation.isCancelled, "apply cancelled")
                // A completed BINLOG GTID can leave GTID_NEXT undefined. Reset
                // before SQL metadata/scratch DDL; never after an uncertain write.
                if config.target.preserveSourceGTIDs { try resetSourceGTID() }
                try resetDMLSession()
                _ = try query("SET SESSION unique_checks=1")
                if config.target.preserveSourceGTIDs && !contract.transactional {
                    try preflightMyISAMGTIDSupport()
                }
            }
        } catch {
            return .init(
                acknowledged: Array(repeating: 0, count: groups.count), failure: error,
                diagnostic: .init(
                    reason: String(describing: error), statement: .init(), rows: [],
                    ddlGTID: nil, ddlSQL: nil, transactionOutcome: "notStarted",
                    targetSQL: (error as? ApplyError)?.targetSQL),
                discardUnwritten: error is TargetConnectionFailure)
        }
        if config.target.preserveSourceGTIDs {
            return executePreservingGTIDs(
                groups, cancellation: cancellation, maximumInsertBytes: maximumInsertBytes,
                checkSourceFailure: checkSourceFailure)
        }
        let write: (Mutation) throws -> Void = {
            try checkSourceFailure()
            try self.apply($0)
        }
        let insert: ([Mutation]) throws -> Void = {
            try checkSourceFailure()
            try self.applyInserts($0)
        }
        if config.replicationProfile.transactional {
            return InnoDBExecution.run(
                groups, cancellation: cancellation,
                maximumInsertRows: config.batchPolicy.maximumInsertRows, maximumInsertBytes: maximumInsertBytes,
                prepare: { group in
                    try self.profile("transaction.prepare") {
                        try checkSourceFailure()
                        try self.prepareDML(group)
                    }
                },
                skipErrors: config.skipErrorPolicy,
                begin: {
                    try self.profile("transaction.begin") {
                        try checkSourceFailure()
                        _ = try self.query("START TRANSACTION", textProtocol: true)
                    }
                },
                commit: {
                    try self.profile("transaction.commit") {
                        _ = try self.query("COMMIT", textProtocol: true, mutation: true)
                    }
                },
                rollback: {
                    try self.profile("transaction.rollback") { _ = try self.query("ROLLBACK", textProtocol: true) }
                },
                write: write, insert: insert, resetTrace: { self.statementTrace = .init() },
                trace: { self.statementTrace })
        }
        return DMLExecution.run(
            groups, cancellation: cancellation,
            maximumInsertRows: config.batchPolicy.maximumInsertRows, maximumInsertBytes: maximumInsertBytes,
            lock: {
                try checkSourceFailure()
                try self.lock($0)
            }, write: write, insert: insert,
            completedGroup: completedDMLGroup, resetTrace: { self.statementTrace = .init() },
            trace: { self.statementTrace })
    }
}

extension TargetSession {
    private func executePreservingGTIDs(
        _ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
        maximumInsertBytes: Int, checkSourceFailure: () throws -> Void
    ) -> DMLExecution.Outcome {
        var counts = Array(repeating: 0, count: groups.count)
        var skipped: [Int: SkippedApplyError] = [:]
        for (index, item) in groups.enumerated() {
            statementTrace = .init()
            do {
                try require(!cancellation.isCancelled, "apply cancelled")
                try checkSourceFailure()
                let identity = item.group.gtid!
                try checkSourceGTID(identity)
                if !contract.transactional {
                    try require(
                        item.mutations.allSatisfy { $0.table.database.lowercased() != "_mysql_replicator_gtid" },
                        "source table conflicts with the reserved GTID scratch database")
                }
                try prepareDML(item)
                if !contract.transactional {
                    if DMLExecution.canAutocommit(
                        item, maximumInsertRows: config.batchPolicy.maximumInsertRows,
                        maximumInsertBytes: maximumInsertBytes)
                    {
                        try lock(item.mutations[0].table)
                        try sourceStatement(identity) {
                            if item.mutations.count == 1 {
                                try apply(item.mutations[0])
                            } else {
                                try applyInserts(item.mutations)
                            }
                        }
                    } else {
                        try applyMyISAMGTIDGroup(item)
                    }
                    counts[index] = item.mutations.count
                    try completedDMLGroup()
                    continue
                }
                let single = DMLExecution.canAutocommit(
                    item, maximumInsertRows: config.batchPolicy.maximumInsertRows,
                    maximumInsertBytes: maximumInsertBytes)
                let outcome = InnoDBExecution.run(
                    [item], cancellation: cancellation,
                    maximumInsertRows: config.batchPolicy.maximumInsertRows, maximumInsertBytes: maximumInsertBytes,
                    skipErrors: config.skipErrorPolicy,
                    begin: {
                        try self.assignSourceGTID(identity)
                        _ = try self.query("START TRANSACTION", textProtocol: true)
                    },
                    commit: {
                        _ = try self.query("COMMIT", textProtocol: true, mutation: true)
                        try self.resetSourceGTID()
                    },
                    rollback: {
                        _ = try self.query("ROLLBACK", textProtocol: true)
                        try self.resetSourceGTID()
                    },
                    write: { mutation in
                        try checkSourceFailure()
                        if single {
                            try self.sourceStatement(identity) { try self.apply(mutation) }
                        } else {
                            try self.apply(mutation)
                        }
                    },
                    insert: { mutations in
                        try checkSourceFailure()
                        if single {
                            try self.sourceStatement(identity) { try self.applyInserts(mutations) }
                        } else {
                            try self.applyInserts(mutations)
                        }
                    }, resetTrace: { self.statementTrace = .init() }, trace: { self.statementTrace })
                counts[index] = outcome.acknowledged[0]
                if let error = outcome.skipped[0] {
                    try resetSourceGTID()
                    try emptySourceGTID(identity)
                    skipped[index] = error
                }
                if let failure = outcome.failure {
                    return .init(
                        acknowledged: counts, failure: failure, diagnostic: outcome.diagnostic,
                        discardUnwritten: outcome.discardUnwritten, skipped: skipped)
                }
            } catch {
                let rows = groups.enumerated().flatMap { groupIndex, group in
                    group.mutations.enumerated().map { ordinal, mutation in
                        TargetFailureDiagnostic.Rows(
                            gtid: group.id, database: mutation.table.database, table: mutation.table.table,
                            firstOrdinal: ordinal, count: 1,
                            disposition: groupIndex < index
                                ? "acknowledged"
                                : groupIndex > index || statementTrace.phase == .notIssued
                                    ? "notIssued" : "possiblyExecuted")
                    }
                }
                return .init(
                    acknowledged: counts, failure: error,
                    diagnostic: .init(
                        reason: String(describing: error), statement: statementTrace, rows: rows, ddlGTID: nil,
                        ddlSQL: nil, targetSQL: (error as? ApplyError)?.targetSQL),
                    discardUnwritten: error is TargetConnectionFailure && statementTrace.phase == .notIssued,
                    skipped: skipped)
            }
        }
        return .init(acknowledged: counts, failure: nil, skipped: skipped)
    }
}
