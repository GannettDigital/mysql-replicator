import Foundation
import CSQLite
import ReplicatorCodec
import ReplicatorCapture
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// SQLite invokes the hook after a successful WAL commit. It only records sizes;
/// returning an error here would misleadingly report failure after commit.
private final class WALGrowth {
    var frames: Int64 = 0
    var growthFrames: Int64 = 0
    var bytes: Int64 { frames == 0 ? 0 : 32+frames*(4096+24) }
    func committed(frames: Int32) {
        let next = Int64(frames)
        growthFrames += next >= self.frames ? next-self.frames : next
        self.frames = next
    }
}

/// Journal with explicit initialization and validated clean-stop reopening. Each completed group is a durable GTID delta. Old
/// completed history is eligible for deletion only under storage pressure and
/// only after a covering snapshot has committed. No uncertain target write is retried.
final class StateStore {
    private var db: OpaquePointer?
    private var statements: SQLiteStatementCache?
    private var relay: FileHandle?
    private var writerLock: FileHandle?
    private(set) var targetUUID: String?
    private var baseline: BinlogCoordinate?
    var currentSchemas: [ApplyTable] { schemas.values.map { $0.1 } }
    private(set) var relayLength: UInt64 = 0
    private var groupStart: UInt64 = 0
    private var completedGTIDs: GTIDSet
    private(set) var transactions = 0
    private(set) var rows = 0
    private(set) var ddlApplied = 0
    private(set) var applied: BinlogCoordinate?
    private(set) var pendingGTID: String?
    private var pendingSequence: Int64 = 0
    private var pendingBatch: [PreparedDMLGroup] = []
    private var sequence: Int64 = 0
    private var snapshotSequence: Int64 = 0
    private var skipBoundary: BinlogCoordinate?
    private var schemas: [String:(Int64,ApplyTable)] = [:]
    private var inTransaction = false
    private var maintenance = false
    private var ready = false
    // Used serially by this store, including formatting retention cutoffs.
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter=ISO8601DateFormatter()
        formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter
    }()
    private let now: () -> Date
    private let freeDisk: (URL) throws -> Int64
    private let uptime: () -> Double
    private let wal = WALGrowth()
    private var capacity = CapacityWindow()
    let directory: URL
    let maximumBytes: UInt64
    let applierProfiling: Bool
    let timings: StageTimings
    let policy: StoragePolicy
    let compatibility: CompatibilityPolicy
    let replicationProfile: ReplicationProfile
    // Reserve enough of the total SQLite budget for a transaction touching every
    // database page, its WAL frame headers, shared memory, and maintenance.
    var databaseLimit: Int64 { ((policy.maximumSQLiteBytes - 131072) / 3 / 4096) * 4096 }
    init(configuration c: ApplyConfiguration, initialize: Bool = true, timings: StageTimings = .init(), skipGTIDs: GTIDSet? = nil, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         freeDisk: @escaping (URL) throws -> Int64 = StateStore.availableSpace) throws {
        self.timings = timings
        applierProfiling = c.applierProfiling ?? false
        directory = URL(fileURLWithPath:c.stateDirectory).standardizedFileURL
        maximumBytes = c.maximumRelayBytes ?? 256*1024*1024
        policy = c.policy; try policy.validate()
        compatibility = c.compatibilityPolicy; try compatibility.validate()
        replicationProfile = c.replicationProfile
        self.now = now; self.freeDisk = freeDisk; self.uptime = uptime
        completedGTIDs = try GTIDSet(c.source.start.executedGTIDs)
        try require(skipGTIDs == nil || !initialize,"skip requires existing state")
        if initialize {
            guard mkdir(directory.path,0o700) == 0 else { throw ApplyError("state directory must be new for --initialize; omit --initialize to resume saved STOPPED state") }
        } else {
            var isDirectory: ObjCBool = false
            try require(FileManager.default.fileExists(atPath:directory.path,isDirectory:&isDirectory) && isDirectory.boolValue,
                "saved state directory is missing; use --initialize only for an externally prepared baseline")
        }
        do {
            let lockFD = open(directory.appendingPathComponent("writer.lock").path,O_RDWR|O_CREAT,0o600)
            guard lockFD >= 0 else { throw ApplyError("cannot open state writer lock") }
            writerLock = FileHandle(fileDescriptor:lockFD,closeOnDealloc:true)
            try require(flock(lockFD,LOCK_EX|LOCK_NB) == 0,"state directory already has an active writer")
            if !initialize {
                try reopen(configuration:c,skipGTIDs:skipGTIDs)
                return
            }
            baseline = try coordinate(c.source.start.file,c.source.start.position.map(String.init))
            try Self.syncDirectory(directory.deletingLastPathComponent())
            try checkDisk(extra:policy.maximumSQLiteBytes)
            let fd = open(directory.appendingPathComponent("relay.frames").path,O_WRONLY|O_CREAT|O_EXCL,0o600)
            guard fd >= 0 else { throw ApplyError("cannot create relay file") }
            relay = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {throw ApplyError("cannot create SQLite state")}
            sqlite3_busy_timeout(db,1000)
            try execute("PRAGMA page_size=4096")
            try execute("PRAGMA auto_vacuum=INCREMENTAL")
            try execute("PRAGMA max_page_count=\(databaseLimit/4096)")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA journal_size_limit=1048576")
            try execute("PRAGMA cache_spill=OFF")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA wal_autocheckpoint=0")
            installWALTracking()
            try execute("PRAGMA user_version=9")
            try createProfileJournal()
            try execute("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),lifecycle TEXT NOT NULL,source_uuid TEXT NOT NULL,target_uuid TEXT,baseline_file TEXT,baseline_position TEXT,baseline_gtids TEXT NOT NULL,applied_file TEXT,applied_position TEXT,applied_sequence INTEGER NOT NULL DEFAULT 0,transactions_applied INTEGER NOT NULL DEFAULT 0,rows_applied INTEGER NOT NULL DEFAULT 0,ddl_applied INTEGER NOT NULL DEFAULT 0,durable_relay_length INTEGER NOT NULL DEFAULT 0,active_gtid TEXT,updated_at TEXT NOT NULL,last_applied_at TEXT,diagnostic TEXT)")
            try execute("CREATE TABLE schemas(id INTEGER PRIMARY KEY,identity TEXT NOT NULL,current INTEGER NOT NULL DEFAULT 1,retired_at TEXT,discovered_at TEXT NOT NULL,source_file TEXT NOT NULL,source_position TEXT NOT NULL,event_hash TEXT NOT NULL,schema_json TEXT NOT NULL,wire_json TEXT NOT NULL)")
            try execute("CREATE UNIQUE INDEX schemas_current ON schemas(identity) WHERE current=1")
            try execute("CREATE TABLE ddl_intents(gtid TEXT PRIMARY KEY,before_schema_id INTEGER,after_schema_id INTEGER,target_sql TEXT NOT NULL,database_json TEXT,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT)")
            try execute("CREATE TABLE groups(sequence INTEGER PRIMARY KEY,gtid TEXT UNIQUE NOT NULL,source_file TEXT NOT NULL,start_position TEXT NOT NULL,end_position TEXT NOT NULL,relay_start INTEGER NOT NULL,relay_end INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT)")
            try createDDLSkips()
            try createCompatibilityJournal()
            try execute("CREATE INDEX groups_retention ON groups(status,completed_at)")
            try execute("CREATE TABLE row_intents(gtid TEXT NOT NULL,ordinal INTEGER NOT NULL,source_event_offset TEXT NOT NULL,source_row INTEGER NOT NULL,schema_id INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT,PRIMARY KEY(gtid,ordinal))")
            try execute("CREATE TABLE snapshots(id INTEGER PRIMARY KEY,covered_sequence INTEGER NOT NULL,gtids TEXT NOT NULL,source_file TEXT,source_position TEXT,created_at TEXT NOT NULL)")
            try execute("INSERT INTO state(id,lifecycle,source_uuid,target_uuid,baseline_file,baseline_position,baseline_gtids,updated_at) VALUES(1,'STARTING',?,?,?,?,?,?)",[c.source.sourceUUID,nil,c.source.start.file,c.source.start.position.map(String.init),completedGTIDs.canonical,timestamp()])
            try snapshot()
            try checkpoint()
            ready = true
            try Self.syncDirectory(directory)
        } catch {closeDatabase(); try? relay?.close(); relay=nil; throw error}
    }
    deinit {try? relay?.close(); closeDatabase(); try? writerLock?.close()}
    private func closeDatabase() {
        statements?.close(); statements=nil
        sqlite3_close(db); db=nil
    }

    private func coordinate(_ file: String?, _ position: String?) throws -> BinlogCoordinate? {
        if file == nil && position == nil { return nil }
        guard let file, !file.isEmpty, !file.utf8.contains(0), file.utf8.count <= 255,
              let position, let n = UInt32(position), n >= 4 else { throw ApplyError("invalid saved binlog coordinate") }
        return BinlogCoordinate(file:file,position:UInt64(n))
    }
    private func reopen(configuration c: ApplyConfiguration, skipGTIDs: GTIDSet?) throws {
        try require(sqliteBytes <= policy.maximumSQLiteBytes,"saved SQLite exceeds configured storage limit")
        guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
            throw ApplyError("cannot open existing SQLite state; no new state was initialized")
        }
        sqlite3_busy_timeout(db,1000)
        let version=try number("PRAGMA user_version")
        try require([4,5,6,7,8,9].contains(version),"unsupported saved state version")
        if version >= 9 {
            try require(try query("SELECT profile FROM replication_profile WHERE id=1") == [[replicationProfile.rawValue]],"replication profile differs from saved state")
        } else {
            try require(replicationProfile == .mysql84To57MyISAM,"legacy state belongs to the MyISAM profile; reverse replication requires a new baseline")
        }
        if version >= 8 {
            let saved = try query("SELECT policy_json FROM compatibility WHERE id=1")
            guard saved.count == 1, let json = saved[0][0] else { throw ApplyError("missing saved compatibility policy") }
            let policy = try JSONDecoder().decode(CompatibilityPolicy.self,from:Data(json.utf8))
            try require(policy == compatibility,"compatibility.collations differs from saved state; restore the original mapping or initialize a newly prepared baseline")
        } else {
            try require(compatibility.collations.isEmpty,"legacy state uses strict collation semantics; enabling compatibility.collations requires a newly prepared baseline")
        }
        try require(version != 4 || skipGTIDs == nil,"format-4 BLOCKED state requires resolution with its original runtime before upgrading")
        try require(try query("PRAGMA quick_check") == [["ok"]],"saved SQLite integrity check failed")
        let states = try query("SELECT lifecycle,source_uuid,target_uuid,baseline_file,baseline_position,baseline_gtids,applied_file,applied_position,applied_sequence,transactions_applied,rows_applied,ddl_applied,durable_relay_length,active_gtid,diagnostic FROM state WHERE id=1")
        try require(states.count == 1,"missing saved replication state")
        let r = states[0]
        if let skipGTIDs {
            try require(r[0] == "BLOCKED" && r[13] != nil,"skip requires BLOCKED state with a captured pending GTID")
            let id = r[13]!
            _ = try singleton(id)
            try require(try !skipGTIDs.isEmpty && skipGTIDs == GTIDSet(id),
                "skip set must equal the captured pending GTID; uncaptured or additional GTIDs cannot be skipped")
            pendingGTID=id
        } else {
            try require(r[0] == "STOPPED" && r[13] == nil && r[14] == nil,
                "saved state must be cleanly STOPPED; BLOCKED, unfinished and crash recovery require explicit resolution")
        }
        try require(r[1]?.lowercased() == c.source.sourceUUID.lowercased(),"saved source UUID differs from configuration")
        guard let uuid = r[2], UUID(uuidString:uuid) != nil else { throw ApplyError("saved target UUID is missing or invalid") }
        targetUUID = uuid.lowercased()
        baseline = try coordinate(r[3],r[4]); applied = try coordinate(r[6],r[7])
        guard let baseText = r[5], let seq = Int64(r[8] ?? ""), seq >= 0, seq < Int64.max,
              let tx = Int(r[9] ?? ""), tx >= 0, Int64(tx) == seq,
              let count = Int(r[10] ?? ""), count >= 0,
              let ddl = Int(r[11] ?? ""), ddl >= 0, ddl <= tx,
              let length = UInt64(r[12] ?? ""), length <= maximumBytes else { throw ApplyError("invalid saved progress or relay limit") }
        try require(seq == 0 ? (count == 0 && ddl == 0) : applied != nil,"saved checkpoint does not match applied work")
        if let id = pendingGTID {
            let pending = try query("SELECT sequence,source_file,start_position,end_position,relay_start,relay_end,status,completed_at FROM groups WHERE gtid=?",[id])
            guard pending.count == 1 else { throw ApplyError("skip requires one captured pending group") }
            let p=pending[0]
            guard Int64(p[0] ?? "") == seq+1, p[6] == "PENDING", p[7] == nil,
                  let start = try coordinate(p[1],p[2]), let end = try coordinate(p[1],p[3]), start.position < end.position,
                  let relayStart=UInt64(p[4] ?? ""), let relayEnd=UInt64(p[5] ?? ""), relayStart < relayEnd, relayEnd == length else {
                throw ApplyError("invalid pending group boundary; cannot skip")
            }
            if let applied, applied.file == start.file { try require(applied.position <= start.position,"pending group precedes applied boundary") }
            try require(try query("SELECT 1 FROM row_intents WHERE gtid=? UNION ALL SELECT 1 FROM ddl_intents WHERE gtid=? LIMIT 1",[id,id]).isEmpty,
                "cannot skip a group with target write intents; partial or uncertain writes require manual resolution")
            try require(try query("SELECT 1 FROM groups WHERE gtid!=? AND (status!='APPLIED' OR sequence>?) LIMIT 1",[id,String(seq)]).isEmpty,"saved state contains other unresolved groups")
            skipBoundary=end
        } else {
            try require(try number("SELECT COUNT(*) FROM groups WHERE status!='APPLIED' OR sequence>\(seq)") == 0,"saved state contains unresolved groups")
        }
        try require(try number("SELECT COUNT(*) FROM row_intents WHERE status!='DONE'") == 0 && number("SELECT COUNT(*) FROM ddl_intents WHERE status!='DONE'") == 0,"saved state contains unresolved intents")
        let snapshots = try query("SELECT covered_sequence,gtids,source_file,source_position FROM snapshots ORDER BY id DESC LIMIT 1")
        guard let snap = snapshots.first, let covered = Int64(snap[0] ?? ""), covered >= 0, covered <= seq, let gtids = snap[1] else { throw ApplyError("missing or invalid covering GTID snapshot") }
        completedGTIDs = try GTIDSet(gtids)
        if skipGTIDs != nil && covered < seq {
            var expected=covered
            var boundary=try coordinate(snap[2],snap[3])
            for delta in try query("SELECT sequence,gtid,source_file,end_position FROM groups WHERE status='APPLIED' AND sequence>? ORDER BY sequence",[String(covered)]) {
                expected += 1
                try require(Int64(delta[0] ?? "") == expected,"saved applied GTID history has a gap")
                let identity=try singleton(delta[1] ?? "")
                try require(!completedGTIDs.contains(sid:identity.sid,sequence:identity.sequence),"duplicate applied GTID delta")
                try completedGTIDs.include(sid:identity.sid,sequence:identity.sequence)
                boundary=try coordinate(delta[2],delta[3])
            }
            try require(expected == seq && boundary == applied,"saved applied history does not reach checkpoint")
        } else {
            try require(covered == seq,"clean stop lacks a covering GTID snapshot")
            try require(try coordinate(snap[2],snap[3]) == applied,"snapshot and applied coordinates differ")
        }
        let base = try GTIDSet(baseText)
        // A skip can advance coverage before the first successfully applied group.
        try require(completedGTIDs.covers(base) && (seq != 0 || ((completedGTIDs == base) == (applied == nil))),"saved GTID coverage differs from baseline")
        if let id=pendingGTID {
            let identity=try singleton(id)
            try require(!completedGTIDs.contains(sid:identity.sid,sequence:identity.sequence),"pending GTID is already covered")
        }
        for row in try query("SELECT gtid FROM groups WHERE status='APPLIED'") {
            guard let id = row[0] else { throw ApplyError("missing saved group GTID") }
            try require(try completedGTIDs.covers(GTIDSet(id)),"snapshot does not cover saved applied groups")
        }
        sequence=seq; snapshotSequence=covered; transactions=tx; rows=count; ddlApplied=ddl
        for row in try query("SELECT id,identity,schema_json FROM schemas WHERE current=1") {
            guard let id=Int64(row[0] ?? ""), let json=row[2] else { throw ApplyError("invalid saved schema") }
            let table=try JSONDecoder().decode(ApplyTable.self,from:Data(json.utf8)); try table.validate()
            let identity=String(decoding:try JSONEncoder().encode([table.database,table.table]),as:UTF8.self)
            try require(row[1] == identity && schemas[table.identity] == nil && schemas.count < maximumCachedTables,"invalid saved schema identity/cache")
            schemas[table.identity]=(id,table)
        }
        // Resume from the applied boundary, never from received-but-unapplied bytes.
        let fd=open(directory.appendingPathComponent("relay.frames").path,O_WRONLY|O_APPEND)
        guard fd >= 0 else { throw ApplyError("saved relay file is missing") }
        relay=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        try require(try relay!.seekToEnd() == length,"saved relay length differs from durable state")
        relayLength=length; groupStart=length
        _ = try captureConfiguration(c.source)
        try checkDisk(extra:policy.maximumSQLiteBytes)
        try require(try number("PRAGMA page_size") == 4096 && number("PRAGMA page_count") <= databaseLimit/4096,"saved SQLite exceeds configured page budget")
        try execute("PRAGMA max_page_count=\(databaseLimit/4096)")
        try require(try query("PRAGMA journal_mode=WAL").first?.first == "wal","saved SQLite must use WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA journal_size_limit=1048576")
        try execute("PRAGMA cache_spill=OFF")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("PRAGMA wal_autocheckpoint=0")
        installWALTracking()
        if version == 4 {
            // Old runtimes accepted only the primary index. Validate every
            // retained schema before changing the version; never bless unknown data.
            for row in try query("SELECT schema_json FROM schemas") {
                guard let json=row[0] else {throw ApplyError("missing legacy schema")}
                let table=try JSONDecoder().decode(ApplyTable.self,from:Data(json.utf8)); try table.validate()
                try require(table.secondaryIndexes.isEmpty,"format-4 state contains unsupported index metadata")
            }
        }
        // Preserve every existing relay byte and offset. New frames carry their
        // own binary version; inspection supports legacy JSON and mixed files.
        // Version 7 adds skipped-DDL history, pruned with its completed groups.
        // Version 8 pins collation policy and adds original SQL/schema audit.
        // Version 9 pins the source/target replication profile.
        // Older runtimes reject newer state rather than orphan audit records.
        if version < 9 {
            try atomic {
                if version < 7 { try createDDLSkips() }
                if version < 8 { try createCompatibilityJournal() }
                try createProfileJournal()
                try execute("PRAGMA user_version=9")
            }
        }
        ready=true
    }
    private func createProfileJournal() throws {
        try execute("CREATE TABLE replication_profile(id INTEGER PRIMARY KEY CHECK(id=1),profile TEXT NOT NULL)")
        try execute("INSERT INTO replication_profile VALUES(1,?)",[replicationProfile.rawValue])
    }
    private func createCompatibilityJournal() throws {
        try execute("CREATE TABLE compatibility(id INTEGER PRIMARY KEY CHECK(id=1),policy_json TEXT NOT NULL)")
        try execute("INSERT INTO compatibility VALUES(1,?)",[String(decoding:try JSONEncoder().encode(compatibility),as:UTF8.self)])
        try execute("CREATE TABLE ddl_details(gtid TEXT PRIMARY KEY,source_sql TEXT NOT NULL,context_json TEXT,policy_json TEXT NOT NULL,transitions_json TEXT NOT NULL)")
    }
    private func createDDLSkips() throws {
        try execute("CREATE TABLE ddl_skips(gtid TEXT PRIMARY KEY,database_name TEXT NOT NULL,object_name TEXT NOT NULL,source_sql TEXT NOT NULL,reason TEXT NOT NULL,created_at TEXT NOT NULL)")
    }
    private func singleton(_ text: String) throws -> (sid:String,sequence:String) {
        let parts=text.split(separator:":",omittingEmptySubsequences:false)
        guard parts.count == 2, UUID(uuidString:String(parts[0])) != nil,
              let n=UInt64(parts[1]), n > 0 else { throw ApplyError("invalid saved singleton GTID") }
        return (String(parts[0]),String(n))
    }
    /// Explicitly exclude a captured group before any target write was attempted.
    /// All validation happens during reopen, under the same exclusive writer lock.
    func skip() throws -> SkipSummary {
        guard let id=pendingGTID, let boundary=skipBoundary else { throw ApplyError("state was not opened for skip") }
        let identity=try singleton(id)
        var next=completedGTIDs
        try next.include(sid:identity.sid,sequence:identity.sequence)
        let time=timestamp()
        // Do not prune history as a side effect of an operator resolution. Reopen
        // has checked disk/page budgets; FULL WAL and SQLite caps still apply.
        maintenance=true; defer {maintenance=false}
        try atomic {
            try execute("DELETE FROM groups WHERE gtid=? AND status='PENDING'",[id])
            try execute("INSERT INTO snapshots(covered_sequence,gtids,source_file,source_position,created_at) VALUES(?,?,?,?,?)",[String(sequence),next.canonical,boundary.file,String(boundary.position),time])
            try execute("UPDATE state SET applied_file=?,applied_position=?,lifecycle='STOPPED',active_gtid=NULL,diagnostic=NULL,updated_at=? WHERE id=1",[boundary.file,String(boundary.position),time])
        }
        completedGTIDs=next; applied=boundary; pendingGTID=nil; skipBoundary=nil; snapshotSequence=sequence
        return SkipSummary(skippedGTIDSet:try GTIDSet(id).canonical,resumeGTIDSet:next.canonical,resumePosition:boundary,stateDirectory:directory.path)
    }
    func captureConfiguration(_ source: CaptureConfiguration, remainingTransactions: Int? = nil) throws -> CaptureConfiguration {
        let boundary = applied ?? baseline
        let resumed = source.resuming(file:boundary?.file,position:boundary.map { UInt32($0.position) },executedGTIDs:gtids,remainingTransactions:remainingTransactions)
        _ = try resumed.validate()
        return resumed
    }
    static func availableSpace(_ url: URL) throws -> Int64 {
        guard let n = try FileManager.default.attributesOfFileSystem(forPath:url.path)[.systemFreeSize] as? NSNumber else {throw ApplyError("cannot inspect free disk space")}
        return n.int64Value
    }
    func profile<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        if !applierProfiling { return try body() }
        return try timings.measure("apply.detail." + stage,body)
    }
    func timestamp(_ date: Date? = nil) -> String {
        profile("journal.timestamp") {
            timestampFormatter.string(from:date ?? now())
        }
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY); guard fd >= 0 else {throw ApplyError("cannot open state directory")}
        defer {close(fd)}
        guard fsync(fd)==0 else {throw ApplyError("cannot synchronize state directory")}
    }
    private func checkDisk(extra: Int64) throws {
        try require(try timings.measure("storage.free_space", { try freeDisk(directory) }) >= policy.minimumFreeDiskBytes + extra,"storage pressure: free-disk reserve reached; replication stopped")
    }
    private func installWALTracking() {
        wal.frames = max(0,(walBytes-32)/(4096+24))
        sqlite3_wal_hook(db, { context, _, _, frames in
            guard let context else { return SQLITE_OK }
            Unmanaged<WALGrowth>.fromOpaque(context).takeUnretainedValue().committed(frames:frames)
            return SQLITE_OK
        },Unmanaged.passUnretained(wal).toOpaque())
    }
    private func checkpoint() throws {
        let rc = timings.measure("sqlite.checkpoint") { sqlite3_wal_checkpoint_v2(db,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil) }
        try require(rc == SQLITE_OK,"storage pressure: SQLite WAL checkpoint blocked (reader or I/O error)")
        wal.frames = 0
    }
    private func query(_ sql: String,_ args: [String?] = []) throws -> [[String?]] {
        guard let db else { throw ApplyError("SQLite is not open") }
        if statements == nil { statements=SQLiteStatementCache(db:db,timings:timings,profiling:applierProfiling) }
        return try statements!.query(sql,args)
    }

    private func number(_ sql: String,_ args: [String?] = []) throws -> Int64 {Int64(try query(sql,args).first?.first.flatMap{$0} ?? "") ?? 0}
    private func execute(_ sql: String,_ args: [String?] = []) throws {
        if ready && !inTransaction && !maintenance {try ensureCapacity(force:false)}
        _ = try timings.measure(inTransaction || sql.hasPrefix("PRAGMA ") ? "sqlite.statement" : "sqlite.commit") { try query(sql,args) }
    }
    private func atomic(_ body: () throws -> Void) throws {
        if ready && !maintenance {try ensureCapacity(force:false)}
        _ = try query("BEGIN IMMEDIATE"); inTransaction=true
        defer {inTransaction=false}
        do {try body(); _ = try timings.measure("sqlite.commit") { try query("COMMIT") }}
        catch {_ = try? query("ROLLBACK"); throw error}
    }
    var sqliteBytes: Int64 {
        ["state.sqlite","state.sqlite-wal","state.sqlite-shm"].reduce(0) {sum,name in
            sum + ((try? FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
    /// Pressure-triggered, age-gated reclamation. Retention is a minimum age:
    /// young completed records are never evicted merely to keep running.
    var walBytes: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("state.sqlite-wal").path)[.size] as? NSNumber)?.int64Value) ?? 0
    }
    // Keep room for a worst-case next transaction, WAL headers and diagnostics.
    var transactionReserve: Int64 { databaseLimit + databaseLimit/4096*24 + 131072 }
    var checkpointThreshold: Int64 { min(1024*1024, databaseLimit/4) }
    func ensureCapacity(force: Bool = true, incomingRelayBytes: Int64 = 0) throws {
        // Always cheap: a very large group cannot bypass the WAL bound merely
        // because no source transaction has completed yet.
        if wal.bytes >= checkpointThreshold { try checkpoint() }
        if force || capacity.needsInspection(sequence:sequence,time:uptime(),relay:relayLength,
            incoming:incomingRelayBytes,growth:wal.growthFrames*4096,databaseLimit:databaseLimit,policy:policy) {
            try timings.measure("sqlite.capacity") { try checkCapacity(incomingRelayBytes:incomingRelayBytes) }
        }
        try require(databaseLimit+wal.bytes+131072+transactionReserve < policy.maximumSQLiteBytes,
                    "storage pressure: SQLite transaction reserve exhausted")
    }
    private func checkCapacity(incomingRelayBytes: Int64) throws {
        if walBytes >= checkpointThreshold || sqliteBytes >= policy.maximumSQLiteBytes-transactionReserve {
            try checkpoint()
        }
        let free = try timings.measure("storage.free_space") { try freeDisk(directory) }
        try require(free >= policy.minimumFreeDiskBytes+policy.maximumSQLiteBytes+incomingRelayBytes,
                    "storage pressure: free-disk reserve reached; replication stopped")
        var used = try (number("PRAGMA page_count") - number("PRAGMA freelist_count"))*4096
        let threshold = databaseLimit * Int64(policy.pruneAtPercent)/100
        let diskPressure = free < policy.minimumFreeDiskBytes + policy.maximumSQLiteBytes*2
        if used >= threshold || diskPressure {
            maintenance=true; defer {maintenance=false}
            // Durable snapshot first. A crash between this commit and DELETE
            // leaves redundant deltas, never a gap in applied coverage.
            if sequence != snapshotSequence {try snapshot()}
            try checkpoint()
            let cutoff = timestamp(now().addingTimeInterval(-Double(policy.historyRetentionSeconds)))
            repeat {
                var removed: Int64 = 0
                try atomic {
                    try execute("CREATE TEMP TABLE IF NOT EXISTS prune_groups(gtid TEXT PRIMARY KEY)")
                    try execute("DELETE FROM prune_groups")
                    try execute("INSERT INTO prune_groups SELECT gtid FROM groups WHERE status='APPLIED' AND sequence<=? AND completed_at<? ORDER BY sequence LIMIT 128",[String(snapshotSequence),cutoff])
                    removed = try number("SELECT COUNT(*) FROM prune_groups")
                    try execute("DELETE FROM row_intents WHERE gtid IN (SELECT gtid FROM prune_groups)")
                    try execute("DELETE FROM ddl_intents WHERE gtid IN (SELECT gtid FROM prune_groups)")
                    try execute("DELETE FROM ddl_skips WHERE gtid IN (SELECT gtid FROM prune_groups)")
                    try execute("DELETE FROM ddl_details WHERE gtid IN (SELECT gtid FROM prune_groups)")
                    try execute("DELETE FROM groups WHERE gtid IN (SELECT gtid FROM prune_groups)")
                    try execute("DELETE FROM snapshots WHERE covered_sequence<? AND created_at<?",[String(snapshotSequence),cutoff])
                    try execute("DELETE FROM schemas WHERE current=0 AND retired_at<? AND NOT EXISTS(SELECT 1 FROM row_intents WHERE schema_id=schemas.id) AND NOT EXISTS(SELECT 1 FROM ddl_intents WHERE before_schema_id=schemas.id OR after_schema_id=schemas.id)",[cutoff])
                }
                try checkpoint()
                try execute("PRAGMA incremental_vacuum(128)")
                try checkpoint()
                used = try (number("PRAGMA page_count") - number("PRAGMA freelist_count"))*4096
                if removed == 0 {break}
            } while used >= threshold
        }
        // Leave a margin for the next write/diagnostic. max_page_count is the
        // independent hard limit if a single oversized operation exceeds it.
        try require(used < databaseLimit * 95/100 && sqliteBytes < policy.maximumSQLiteBytes - transactionReserve,"storage pressure: SQLite budget reached; no eligible old history can free enough space")
        capacity.record(sequence:sequence,time:uptime(),relay:relayLength,free:free,used:used)
        wal.growthFrames = 0
    }
    private func snapshot() throws {
        try profile("journal.snapshot") {
            if ready && !maintenance {try ensureCapacity(force:false)}
            if ready && sequence == snapshotSequence {return}
            let wasMaintenance=maintenance; maintenance=true
            defer {maintenance=wasMaintenance}
            try atomic {
                try execute("INSERT INTO snapshots(covered_sequence,gtids,source_file,source_position,created_at) VALUES(?,?,?,?,?)",[String(sequence),completedGTIDs.canonical,applied?.file,applied.map{String($0.position)},timestamp()])
            }
            snapshotSequence=sequence
        }
    }
    private func insertSchema(_ table: ApplyTable,event: DecodedEvent,coordinate: BinlogCoordinate) throws -> Int64 {
        let schema=String(decoding:try JSONEncoder().encode(table),as:UTF8.self)
        let wire=String(decoding:try JSONEncoder().encode(event.wireColumns),as:UTF8.self)
        try execute("INSERT INTO schemas(identity,discovered_at,source_file,source_position,event_hash,schema_json,wire_json) VALUES(?,?,?,?,?,?,?)",[String(decoding:try JSONEncoder().encode([table.database,table.table]),as:UTF8.self),timestamp(),coordinate.file,String(coordinate.position),event.sha256,schema,wire])
        return sqlite3_last_insert_rowid(db)
    }
    func schema(_ table: ApplyTable,event: DecodedEvent,coordinate: BinlogCoordinate) throws {
        try profile("journal.schema") {
            if let old=schemas[table.identity] {try require(old.1==table,"schema changed without ordered DDL");return}
            try require(schemas.count<maximumCachedTables,"schema cache limit reached")
            schemas[table.identity]=(try insertSchema(table,event:event,coordinate:coordinate),table)
        }
    }
    func ddlIntent(_ plan: PreparedDDL,event: DecodedEvent,coordinate: BinlogCoordinate) throws {
        try require(pendingGTID != nil,"DDL intent without pending group")
        if let before=plan.before {try schema(before,event:event,coordinate:coordinate)}
        for change in plan.additional {
            if let before=change.before {try schema(before,event:event,coordinate:coordinate)}
        }
        let beforeID=plan.statement.name.flatMap{schemas[$0.identity]?.0}
        let databaseJSON=try plan.database.map{String(decoding:try JSONEncoder().encode($0),as:UTF8.self)}
        guard case .query(let source) = event.control else { throw ApplyError("DDL intent lacks source query") }
        let contextJSON = try DDLQueryContextDiagnostic(query:source).map { String(decoding:try JSONEncoder().encode($0),as:UTF8.self) }
        let transitions = plan.additional + ((plan.before != nil || plan.after != nil) ? [SchemaTransition(before:plan.before,after:plan.after)] : [])
        let policyJSON = String(decoding:try JSONEncoder().encode(compatibility),as:UTF8.self)
        let transitionsJSON = String(decoding:try JSONEncoder().encode(transitions),as:UTF8.self)
        try atomic {
            try execute("INSERT INTO ddl_intents(gtid,before_schema_id,target_sql,database_json,status,created_at) VALUES(?,?,?,?,'PENDING',?)",[pendingGTID,beforeID.map(String.init),plan.sql,databaseJSON,timestamp()])
            try execute("INSERT INTO ddl_details VALUES(?,?,?,?,?)",[pendingGTID,String(decoding:source.sql,as:UTF8.self),contextJSON,policyJSON,transitionsJSON])
        }
    }
    func append(_ record: LiveRecord) throws {
        let bytes: Data = try profile("relay.base64") {
            guard let encoded = record.event?.rawBase64 ?? record.rawBase64, let bytes = Data(base64Encoded:encoded) else {throw ApplyError("relay event lacks original bytes")}
            return bytes
        }
        let metadata = try profile("relay.metadata") {
            try RelayMetadata(kind:record.kind,file:record.file,observedPosition:record.observedPosition).encoded()
        }
        let frame = profile("relay.frame") {
            var frame = Data()
            for n in [UInt32(metadata.count),UInt32(bytes.count)] {var le=n.littleEndian; withUnsafeBytes(of:&le){frame.append(contentsOf:$0)}}
            frame += metadata; frame += bytes
            return frame
        }
        try require(UInt64(frame.count) <= maximumBytes-relayLength,"relay storage limit reached")
        try ensureCapacity(force:false,incomingRelayBytes:Int64(frame.count))
        try profile("relay.write") { try relay!.write(contentsOf:frame) }
        relayLength += UInt64(frame.count)
    }

    func bindTargetIdentity(_ uuid: String) throws {
        try require(UUID(uuidString:uuid) != nil,"invalid discovered target identity")
        if let targetUUID {
            try require(targetUUID == uuid.lowercased(),"saved target UUID differs from the connected target")
            return
        }
        try execute("UPDATE state SET target_uuid=?,updated_at=? WHERE id=1 AND target_uuid IS NULL",[uuid.lowercased(),timestamp()])
        targetUUID=uuid.lowercased()
    }
    func running() throws {try execute("UPDATE state SET lifecycle='RUNNING',updated_at=? WHERE id=1",[timestamp()])}
    /// One synced relay prefix and one FULL SQLite commit precede every target
    /// write in the batch. Existing tables retain each source group's identity.
    func beginBatch(_ batch: [PreparedDMLGroup]) throws {
        try profile("journal.prepare_batch") {
            try require(pendingGTID == nil && !batch.isEmpty && batch.count <= 256,"invalid pending DML batch")
            var seen=completedGTIDs, relayStart=groupStart
            for item in batch {
                guard let id=item.group.gtid else { throw ApplyError("batch lacks source GTID") }
                try require(!item.mutations.isEmpty && item.relayEnd > relayStart && item.relayEnd <= relayLength,"invalid DML batch relay boundary")
                try require(!seen.contains(sid:id.sid,sequence:id.sequence),"duplicate or excluded batch GTID")
                try profile("journal.gtid") { try seen.include(sid:id.sid,sequence:id.sequence) }
                relayStart=item.relayEnd
                for row in item.mutations { try require(schemas[row.table.identity]?.1 == row.table,"batch schema is not current") }
            }
            try timings.measure("relay.sync") { try relay!.synchronize() }
            let time=timestamp()
            try atomic {
                var start=groupStart
                for (index,item) in batch.enumerated() {
                    try execute("INSERT INTO groups VALUES(?,?,?,?,?,?,?,'PENDING',?,NULL)",[String(sequence+Int64(index)+1),item.id,item.group.start.file,String(item.group.start.position),String(item.group.end.position),String(start),String(item.relayEnd),time])
                    for (ordinal,row) in item.mutations.enumerated() {
                        try execute("INSERT INTO row_intents VALUES(?,?,?,?,?,'PENDING',?,NULL)",[item.id,String(ordinal),row.eventOffset,String(row.rowIndex),String(schemas[row.table.identity]!.0),time])
                    }
                    start=item.relayEnd
                }
                try execute("UPDATE state SET active_gtid=?,durable_relay_length=?,updated_at=? WHERE id=1",[batch[0].id,String(relayLength),time])
            }
            pendingBatch=batch; pendingGTID=batch[0].id; pendingSequence=sequence+1
        }
    }
    /// Commit only the acknowledged prefix. On crash before this commit every
    /// prepared row remains uncertain. No target write is inferred or retried.
    func finishBatch(acknowledgedRows: [Int]) throws {
        try profile("journal.complete_batch") {
            let batch=pendingBatch
            try require(!batch.isEmpty && acknowledgedRows.count == batch.count,"completion without prepared batch")
            var completed=0, rowCount=0, incomplete=false, next=completedGTIDs
            for (index,item) in batch.enumerated() {
                let count=acknowledgedRows[index]
                try require((0...item.mutations.count).contains(count) && (!incomplete || count == 0),"batch acknowledgments are not a contiguous prefix")
                if count == item.mutations.count {
                    completed+=1; rowCount+=count
                    try profile("journal.gtid") { try next.include(sid:item.group.gtid!.sid,sequence:item.group.gtid!.sequence) }
                } else { incomplete=true }
            }
            let active=completed < batch.count ? batch[completed].id : nil
            let end=completed > 0 ? batch[completed-1].group.end : applied
            let time=timestamp()
            try atomic {
                for (index,item) in batch.enumerated() {
                    try require(try query("SELECT status FROM groups WHERE gtid=?",[item.id]) == [["PENDING"]]
                        && number("SELECT COUNT(*) FROM row_intents WHERE gtid=? AND status='PENDING'",[item.id]) == Int64(item.mutations.count),"batch journal no longer matches preparation")
                    if acknowledgedRows[index] > 0 {
                        try execute("UPDATE row_intents SET status='DONE',completed_at=? WHERE gtid=? AND ordinal<?",[time,item.id,String(acknowledgedRows[index])])
                    }
                    if index < completed { try execute("UPDATE groups SET status='APPLIED',completed_at=? WHERE gtid=?",[time,item.id]) }
                }
                try execute("UPDATE state SET applied_file=?,applied_position=?,applied_sequence=?,transactions_applied=?,rows_applied=?,active_gtid=?,updated_at=?,last_applied_at=CASE WHEN CAST(? AS INTEGER)>0 THEN ? ELSE last_applied_at END WHERE id=1",[end?.file,end.map{String($0.position)},String(sequence+Int64(completed)),String(transactions+completed),String(rows+rowCount),active,time,String(completed),time])
            }
            completedGTIDs=next; applied=end; sequence+=Int64(completed); transactions+=completed; rows+=rowCount
            if completed > 0 { groupStart=batch[completed-1].relayEnd }
            pendingGTID=active; pendingSequence=sequence+1
            pendingBatch=Array(batch.dropFirst(completed))
            if sequence-snapshotSequence >= policy.snapshotEveryTransactions { try snapshot() }
        }
    }
    func begin(_ group: CompleteTransaction) throws {
        guard let identity = group.gtid else {throw ApplyError("group lacks GTID")}
        try require(pendingGTID == nil && !completedGTIDs.contains(sid:identity.sid,sequence:identity.sequence),"duplicate or excluded applied GTID")
        let id=identity.sid+":"+identity.sequence
        try timings.measure("relay.sync") { try relay!.synchronize() }
        try atomic {
            try execute("INSERT INTO groups VALUES(?,?,?,?,?,?,?,'PENDING',?,NULL)",[String(sequence+1),id,group.start.file,String(group.start.position),String(group.end.position),String(groupStart),String(relayLength),timestamp()])
            try execute("UPDATE state SET active_gtid=?,durable_relay_length=?,updated_at=? WHERE id=1",[id,String(relayLength),timestamp()])
        }
        pendingGTID=id; pendingSequence=sequence+1
    }
    func intent(_ ordinal: Int,_ mutation: Mutation) throws {
        guard let schema = schemas[mutation.table.identity] else {throw ApplyError("mutation lacks discovered schema")}
        try execute("INSERT INTO row_intents VALUES(?,?,?,?,?,'PENDING',?,NULL)",[pendingGTID,String(ordinal),mutation.eventOffset,String(mutation.rowIndex),String(schema.0),timestamp()])
    }
    func rowDone(_ ordinal: Int) throws {try execute("UPDATE row_intents SET status='DONE',completed_at=? WHERE gtid=? AND ordinal=?",[timestamp(),pendingGTID,String(ordinal)])}
    func complete(_ group: CompleteTransaction,rowCount: Int,ddl: PreparedDDL? = nil,filtered: Bool = false, finalRow: Int? = nil, skippedDDL: SkippedDDL? = nil) throws {
        try require(pendingBatch.isEmpty,"batched DML requires batch completion")
        guard let identity=group.gtid,let pendingGTID,pendingGTID==identity.sid+":"+identity.sequence,(rowCount>0 && ddl==nil && !filtered) || (rowCount==0 && ddl != nil && !filtered) || (filtered && rowCount==0 && ddl==nil) else {throw ApplyError("completion without matching pending group")}
        if let skippedDDL {
            try require(filtered && group.outcome == .statement && group.events.count == 2,"invalid skipped DDL completion")
            guard case .query(let query) = group.events[1].control else { throw ApplyError("missing skipped DDL query") }
            let expected = try DDLPolicy().skippedTrigger(query)
            try require(expected?.sql == skippedDDL.sql && expected?.name == skippedDDL.name && expected?.reason == skippedDDL.reason,"skipped DDL differs from source query")
        }
        if filtered {
            try require(try query("SELECT COUNT(*) FROM row_intents WHERE gtid=?",[pendingGTID]) == [["0"]] && query("SELECT COUNT(*) FROM ddl_intents WHERE gtid=?",[pendingGTID]) == [["0"]],"filtered completion has target write intents")
        }
        if let finalRow {
            try require(rowCount > 0 && ddl == nil && !filtered && finalRow == rowCount-1,
                        "invalid final row completion")
        }
        if ddl != nil {
            try require(group.outcome == .statement && (try number("SELECT COUNT(*) FROM ddl_intents WHERE status='PENDING'")) == 1,"DDL completion without a pending intent")
        }
        var newSchemaID: Int64?
        var additionalIDs: [String:Int64] = [:]
        var next=completedGTIDs; try next.include(sid:identity.sid,sequence:identity.sequence)
        let time=timestamp()
        try atomic {
            if let skippedDDL {
                try execute("INSERT INTO ddl_skips VALUES(?,?,?,?,?,?)",[pendingGTID,skippedDDL.name.database,skippedDDL.name.table,skippedDDL.sql,skippedDDL.reason,time])
            }
            // Only the last, already acknowledged row is folded into this commit.
            // Its previously committed PENDING intent survives any failure here.
            if let finalRow {
                try require(try query("SELECT status FROM row_intents WHERE gtid=? AND ordinal=?",[pendingGTID,String(finalRow)]) == [["PENDING"]], "final row has no pending intent")
                try rowDone(finalRow)
            }
            let done = try query("SELECT COUNT(*) FROM row_intents WHERE gtid=? AND status='DONE'",[pendingGTID])[0][0]
            try require(Int(done ?? "") == rowCount,"cannot complete group with unfinished row intents")

            if let ddl {
                for change in ddl.additional where change.before != change.after {
                    if let before=change.before,let old=schemas[before.identity] {
                        try execute("UPDATE schemas SET current=0,retired_at=? WHERE id=?",[time,String(old.0)])
                    }
                }
                if ddl.preservesSchema {newSchemaID=ddl.statement.name.flatMap{schemas[$0.identity]?.0}}
                else {
                    if let name=ddl.statement.name,let old=schemas[name.identity] {
                        try execute("UPDATE schemas SET current=0,retired_at=? WHERE id=?",[time,String(old.0)])
                    }
                    if let after=ddl.after {newSchemaID=try insertSchema(after,event:group.events[1],coordinate:group.end)}
                }
                // Retire all old names before inserting any new names: an
                // atomic multi-table rename can replace or swap current entries.
                for change in ddl.additional where change.before != change.after {
                    if let after=change.after {additionalIDs[after.identity]=try insertSchema(after,event:group.events[1],coordinate:group.end)}
                }
                try execute("UPDATE ddl_intents SET status='DONE',completed_at=?,after_schema_id=? WHERE gtid=?",[time,newSchemaID.map(String.init),pendingGTID])
            }
            try execute("UPDATE groups SET status='APPLIED',completed_at=? WHERE gtid=?",[time,pendingGTID])
            try execute("UPDATE state SET applied_file=?,applied_position=?,applied_sequence=?,transactions_applied=?,rows_applied=?,ddl_applied=?,active_gtid=NULL,updated_at=?,last_applied_at=? WHERE id=1",[group.end.file,String(group.end.position),String(pendingSequence),String(transactions+1),String(rows+rowCount),String(ddlApplied+(ddl == nil ? 0 : 1)),time,time])
        }
        if let ddl {
            for change in ddl.additional where change.before != change.after {
                if let before=change.before {schemas.removeValue(forKey:before.identity)}
            }
            for change in ddl.additional where change.before != change.after {
                if let after=change.after,let id=additionalIDs[after.identity] {schemas[after.identity]=(id,after)}
            }
            if let name=ddl.statement.name {schemas.removeValue(forKey:name.identity)}
            if let after=ddl.after,let newSchemaID {schemas[after.identity]=(newSchemaID,after)}
            ddlApplied+=1
        }
        completedGTIDs=next; applied=group.end; transactions+=1; rows+=rowCount; sequence=pendingSequence
        self.pendingGTID=nil; groupStart=relayLength
        if sequence-snapshotSequence >= policy.snapshotEveryTransactions {try snapshot()}
    }
    func stopped() throws {
        try require(pendingGTID == nil,"cannot stop cleanly with a pending apply group")
        try timings.measure("relay.sync") { try relay!.synchronize() }
        if sequence != snapshotSequence {try snapshot()}
        try execute("UPDATE state SET lifecycle='STOPPED',durable_relay_length=?,updated_at=? WHERE id=1",[String(relayLength),timestamp()])
        try checkpoint()
    }
    /// In-process reconnect/drain only. Never resolve uncertain target writes
    /// or reopen crashed state here. Retain the journaled, fully applied prefix.
    func discardUnappliedCapture() throws {
        try require(pendingGTID == nil && pendingBatch.isEmpty,"cannot reconnect with pending target intents")
        try require(try number("SELECT COUNT(*) FROM groups WHERE status='PENDING'") == 0
                    && number("SELECT COUNT(*) FROM ddl_intents WHERE status='PENDING'") == 0,"cannot reconnect with unresolved journal entries")
        try require(groupStart <= relayLength,"invalid applied relay boundary")
        try relay!.truncate(atOffset:groupStart)
        relayLength=groupStart
        try relay!.seek(toOffset:groupStart)
        try timings.measure("relay.sync") { try relay!.synchronize() }
        try execute("UPDATE state SET durable_relay_length=?,updated_at=? WHERE id=1",[String(relayLength),timestamp()])
    }
    /// Caller must prove no mutation was issued for any remaining group.
    /// Never used on process restart, ambiguous SQL, or a partially applied group.
    func discardUnwrittenPending() throws {
        try require(try number("SELECT COUNT(*) FROM row_intents WHERE status='DONE' AND gtid IN (SELECT gtid FROM groups WHERE status='PENDING')") == 0,
                    "cannot discard a partially acknowledged group")
        try atomic {
            try execute("DELETE FROM row_intents WHERE gtid IN (SELECT gtid FROM groups WHERE status='PENDING')")
            try execute("DELETE FROM ddl_intents WHERE gtid IN (SELECT gtid FROM groups WHERE status='PENDING')")
            try execute("DELETE FROM ddl_details WHERE gtid IN (SELECT gtid FROM groups WHERE status='PENDING')")
            try execute("DELETE FROM groups WHERE status='PENDING'")
            try execute("UPDATE state SET active_gtid=NULL,updated_at=? WHERE id=1",[timestamp()])
        }
        pendingGTID=nil; pendingBatch=[]
    }
    func recordTargetFailure(_ diagnostic: TargetFailureDiagnostic) throws {
        let data=try JSONEncoder().encode(diagnostic)
        // Failure-only evidence: no extra SQLite commits in the apply hot path.
        try execute("CREATE TABLE IF NOT EXISTS target_failure (id INTEGER PRIMARY KEY CHECK(id=1),diagnostic_json TEXT NOT NULL,created_at TEXT NOT NULL)")
        try execute("INSERT OR REPLACE INTO target_failure VALUES(1,?,?)",[String(decoding:data,as:UTF8.self),timestamp()])
    }
    func block(_ reason: String) throws {
        try timings.measure("relay.sync") { try relay!.synchronize() }
        // Best effort within existing page/WAL caps. Do not attempt retention or
        // a new large snapshot while recording a storage-pressure diagnostic.
        maintenance=true; defer {maintenance=false}
        try execute("UPDATE state SET lifecycle='BLOCKED',diagnostic=?,durable_relay_length=?,updated_at=? WHERE id=1",[String(reason.prefix(1024)),String(relayLength),timestamp()])
        try checkpoint()
    }
    func durableAppliedGTIDs() throws -> String {
        let latest = try query("SELECT covered_sequence,gtids FROM snapshots ORDER BY id DESC LIMIT 1")[0]
        var set = try GTIDSet(latest[1]!)
        for row in try query("SELECT gtid FROM groups WHERE status='APPLIED' AND sequence>? ORDER BY sequence",[latest[0]]) {
            let parts=row[0]!.split(separator:":"); try set.include(sid:String(parts[0]),sequence:String(parts[1]))
        }
        return set.canonical
    }
    var gtids: String {completedGTIDs.canonical}
}
