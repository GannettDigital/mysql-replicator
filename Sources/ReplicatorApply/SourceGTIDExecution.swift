import ReplicatorCodec

/// Source identity rules are separate from engine transaction boundaries.
enum SourceGTIDExecution {
    static func validate(_ identity: SourceGTID, targetVersion: Int) throws {
        _ = try SourceGTID(parsing:identity.canonical)
        try require(identity.tag == nil || targetVersion >= 80400,
            "cannot preserve tagged source GTID \(identity.canonical) on target version \(targetVersion); tags require MySQL 8.4 or later; set target.preserveSourceGTIDs: false to track source GTIDs only in the replicator")
    }
}

extension TargetSession {
    func preflightSourceGTIDs() throws {
        do {try resetSourceGTID()}
        catch let error as ApplyError where error.mysqlErrorNumber == 1227 {
            throw ApplyError("target.preserveSourceGTIDs=true requires permission to SET SESSION GTID_NEXT; MySQL 5.7 requires SUPER; MySQL 8.4 accepts SESSION_VARIABLES_ADMIN or REPLICATION_APPLIER (also SYSTEM_VARIABLES_ADMIN or SUPER); Cloud SQL can restrict these privileges; see docs/GTID_PRESERVATION.md; \(error)",
                             code:error.code,mysqlErrorNumber:error.mysqlErrorNumber,sqlState:error.sqlState)
        }
    }
    func checkSourceGTID(_ identity: SourceGTID) throws {
        guard config.target.preserveSourceGTIDs else { return }
        try SourceGTIDExecution.validate(identity,targetVersion:serverVersionID ?? 0)
        try require(try scalar("SELECT GTID_SUBSET(?,@@GLOBAL.gtid_executed) AS v",[.init(string:identity.canonical)]) == "0",
            "target already executed source GTID \(identity.canonical) but SQLite has not recorded it; inspect the target and saved state before recovery")
    }
    func assignSourceGTID(_ identity: SourceGTID) throws {
        try SourceGTIDExecution.validate(identity,targetVersion:serverVersionID ?? 0)
        // The shared parser accepts only UUID, ASCII tag and numeric sequence.
        _ = try query("SET SESSION GTID_NEXT='\(identity.canonical)'",textProtocol:true)
    }
    func resetSourceGTID() throws {
        _ = try query("SET SESSION GTID_NEXT='AUTOMATIC'",textProtocol:true)
    }
    func emptySourceGTID(_ identity: SourceGTID) throws {
        guard config.target.preserveSourceGTIDs else { return }
        try assignSourceGTID(identity)
        _ = try query("BEGIN",textProtocol:true)
        _ = try query("COMMIT",textProtocol:true,mutation:true)
        try resetSourceGTID()
    }
    /// Set immediately before the actual write, after metadata and JSON scratch
    /// preparation. Restore AUTOMATIC before post-write metadata checks.
    func sourceStatement<T>(_ identity: SourceGTID, _ body: () throws -> T) throws -> T {
        guard config.target.preserveSourceGTIDs else {return try body()}
        try require(statementSourceGTID == nil,"nested source GTID statement")
        statementSourceGTID=identity
        defer {statementSourceGTID=nil}
        let result=try body()
        if statementSourceGTID != nil {
            statementSourceGTID=nil
            try emptySourceGTID(identity)
        }
        return result
    }
}
