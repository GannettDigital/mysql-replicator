import ReplicatorCapture

extension TargetSession {
    /// Engine-specific transaction semantics stay behind the target adapter;
    /// collection, durable intents and completion remain shared orchestration.
    func execute(_ groups: [PreparedDMLGroup], cancellation: CaptureCancellation,
                 maximumInsertBytes: Int, checkSourceFailure: @escaping () throws -> Void) -> DMLExecution.Outcome {
        let write: (Mutation) throws -> Void = { try checkSourceFailure(); try self.apply($0) }
        let insert: ([Mutation]) throws -> Void = { try checkSourceFailure(); try self.applyInserts($0) }
        if config.replicationProfile.transactional {
            return InnoDBExecution.run(groups,cancellation:cancellation,
                maximumInsertRows:config.batchPolicy.maximumInsertRows,maximumInsertBytes:maximumInsertBytes,
                prepare:{ try checkSourceFailure(); try self.prepareDML($0) },
                begin:{ try checkSourceFailure(); _ = try self.query("START TRANSACTION",textProtocol:true) },
                commit:{ _ = try self.query("COMMIT",textProtocol:true,mutation:true) },
                rollback:{ _ = try self.query("ROLLBACK",textProtocol:true) },
                write:write,insert:insert,resetTrace:{ self.statementTrace = .init() },trace:{ self.statementTrace })
        }
        return DMLExecution.run(groups,cancellation:cancellation,
            maximumInsertRows:config.batchPolicy.maximumInsertRows,maximumInsertBytes:maximumInsertBytes,
            lock:{ try checkSourceFailure(); try self.lock($0) },write:write,insert:insert,
            completedGroup:completedDMLGroup,resetTrace:{ self.statementTrace = .init() },trace:{ self.statementTrace })
    }
}
