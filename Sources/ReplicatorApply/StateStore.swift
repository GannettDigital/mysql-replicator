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

/// Journal with explicit initialization and validated clean-stop reopening. Each completed group is a durable GTID delta. Old
/// completed history is eligible for deletion only under storage pressure and
/// only after a covering snapshot has committed. No uncertain target write is retried.
final class StateStore {
    private var db: OpaquePointer?
    private var relay: FileHandle?
    private var writerLock: FileHandle?
    private var targetUUID: String?
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
    private var sequence: Int64 = 0
    private var snapshotSequence: Int64 = 0
    private var skipBoundary: BinlogCoordinate?
    private var schemas: [String:(Int64,ApplyTable)] = [:]
    private var inTransaction = false
    private var maintenance = false
    private var ready = false
    private let now: () -> Date
    private let freeDisk: (URL) throws -> Int64
    let directory: URL
    let maximumBytes: UInt64
    let policy: StoragePolicy
    // Reserve enough of the total SQLite budget for a transaction touching every
    // database page, its WAL frame headers, shared memory, and maintenance.
    var databaseLimit: Int64 { ((policy.maximumSQLiteBytes - 131072) / 3 / 4096) * 4096 }
    init(configuration c: ApplyConfiguration, initialize: Bool = true, skipGTIDs: GTIDSet? = nil, now: @escaping () -> Date = Date.init,
         freeDisk: @escaping (URL) throws -> Int64 = StateStore.availableSpace) throws {
        directory = URL(fileURLWithPath:c.stateDirectory).standardizedFileURL
        maximumBytes = c.maximumRelayBytes ?? 256*1024*1024
        policy = c.policy; try policy.validate()
        self.now = now; self.freeDisk = freeDisk
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
            try execute("PRAGMA journal_size_limit=0")
            try execute("PRAGMA cache_spill=OFF")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA wal_autocheckpoint=64")
            try execute("PRAGMA user_version=4")
            try execute("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),lifecycle TEXT NOT NULL,source_uuid TEXT NOT NULL,target_uuid TEXT,baseline_file TEXT,baseline_position TEXT,baseline_gtids TEXT NOT NULL,applied_file TEXT,applied_position TEXT,applied_sequence INTEGER NOT NULL DEFAULT 0,transactions_applied INTEGER NOT NULL DEFAULT 0,rows_applied INTEGER NOT NULL DEFAULT 0,ddl_applied INTEGER NOT NULL DEFAULT 0,durable_relay_length INTEGER NOT NULL DEFAULT 0,active_gtid TEXT,updated_at TEXT NOT NULL,last_applied_at TEXT,diagnostic TEXT)")
            try execute("CREATE TABLE schemas(id INTEGER PRIMARY KEY,identity TEXT NOT NULL,current INTEGER NOT NULL DEFAULT 1,retired_at TEXT,discovered_at TEXT NOT NULL,source_file TEXT NOT NULL,source_position TEXT NOT NULL,event_hash TEXT NOT NULL,schema_json TEXT NOT NULL,wire_json TEXT NOT NULL)")
            try execute("CREATE UNIQUE INDEX schemas_current ON schemas(identity) WHERE current=1")
            try execute("CREATE TABLE ddl_intents(gtid TEXT PRIMARY KEY,before_schema_id INTEGER,after_schema_id INTEGER,target_sql TEXT NOT NULL,database_json TEXT,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT)")
            try execute("CREATE TABLE groups(sequence INTEGER PRIMARY KEY,gtid TEXT UNIQUE NOT NULL,source_file TEXT NOT NULL,start_position TEXT NOT NULL,end_position TEXT NOT NULL,relay_start INTEGER NOT NULL,relay_end INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT)")
            try execute("CREATE INDEX groups_retention ON groups(status,completed_at)")
            try execute("CREATE TABLE row_intents(gtid TEXT NOT NULL,ordinal INTEGER NOT NULL,source_event_offset TEXT NOT NULL,source_row INTEGER NOT NULL,schema_id INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,completed_at TEXT,PRIMARY KEY(gtid,ordinal))")
            try execute("CREATE TABLE snapshots(id INTEGER PRIMARY KEY,covered_sequence INTEGER NOT NULL,gtids TEXT NOT NULL,source_file TEXT,source_position TEXT,created_at TEXT NOT NULL)")
            try execute("INSERT INTO state(id,lifecycle,source_uuid,target_uuid,baseline_file,baseline_position,baseline_gtids,updated_at) VALUES(1,'STARTING',?,?,?,?,?,?)",[c.source.sourceUUID,nil,c.source.start.file,c.source.start.position.map(String.init),completedGTIDs.canonical,timestamp()])
            try snapshot()
            try checkpoint()
            ready = true
            try Self.syncDirectory(directory)
        } catch {sqlite3_close(db); db=nil; try? relay?.close(); relay=nil; throw error}
    }
    deinit {try? relay?.close(); sqlite3_close(db); try? writerLock?.close()}

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
        try require(try number("PRAGMA user_version") == 4,"unsupported saved state version")
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
            try require(row[1] == identity && schemas[table.identity] == nil && schemas.count < 64,"invalid saved schema identity/cache")
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
        try execute("PRAGMA journal_size_limit=0")
        try execute("PRAGMA cache_spill=OFF")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("PRAGMA wal_autocheckpoint=64")
        ready=true
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
    func captureConfiguration(_ source: CaptureConfiguration) throws -> CaptureConfiguration {
        let boundary = applied ?? baseline
        let resumed = source.resuming(file:boundary?.file,position:boundary.map { UInt32($0.position) },executedGTIDs:gtids)
        _ = try resumed.validate()
        return resumed
    }
    static func availableSpace(_ url: URL) throws -> Int64 {
        guard let n = try FileManager.default.attributesOfFileSystem(forPath:url.path)[.systemFreeSize] as? NSNumber else {throw ApplyError("cannot inspect free disk space")}
        return n.int64Value
    }
    func timestamp(_ date: Date? = nil) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return f.string(from:date ?? now())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY); guard fd >= 0 else {throw ApplyError("cannot open state directory")}
        defer {close(fd)}
        guard fsync(fd)==0 else {throw ApplyError("cannot synchronize state directory")}
    }
    private func checkDisk(extra: Int64) throws {
        try require(try freeDisk(directory) >= policy.minimumFreeDiskBytes + extra,"storage pressure: free-disk reserve reached; replication stopped")
    }
    private func checkpoint() throws {
        let rc = sqlite3_wal_checkpoint_v2(db,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil)
        try require(rc == SQLITE_OK,"storage pressure: SQLite WAL checkpoint blocked (reader or I/O error)")
    }
    private func query(_ sql: String,_ args: [String?] = []) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else {throw ApplyError("SQLite preparation failed")}
        defer {sqlite3_finalize(stmt)}
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (i,arg) in args.enumerated() {
            let rc = arg.map {sqlite3_bind_text(stmt,Int32(i+1),$0,-1,transient)} ?? sqlite3_bind_null(stmt,Int32(i+1))
            try require(rc == SQLITE_OK,"SQLite bind failed")
        }
        var output: [[String?]] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            output.append((0..<sqlite3_column_count(stmt)).map {i in sqlite3_column_text(stmt,i).map {String(cString:$0)}})
            rc = sqlite3_step(stmt)
        }
        try require(rc == SQLITE_DONE,"SQLite operation failed (code \(rc)); replication stopped")
        return output
    }
    private func number(_ sql: String) throws -> Int64 {Int64(try query(sql).first?.first.flatMap{$0} ?? "") ?? 0}
    private func execute(_ sql: String,_ args: [String?] = []) throws {
        if ready && !inTransaction && !maintenance {try ensureCapacity()}
        _ = try query(sql,args)
    }
    private func atomic(_ body: () throws -> Void) throws {
        if ready && !maintenance {try ensureCapacity()}
        _ = try query("BEGIN IMMEDIATE"); inTransaction=true
        defer {inTransaction=false}
        do {try body(); _ = try query("COMMIT")}
        catch {_ = try? query("ROLLBACK"); throw error}
    }
    var sqliteBytes: Int64 {
        ["state.sqlite","state.sqlite-wal","state.sqlite-shm"].reduce(0) {sum,name in
            sum + ((try? FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
    /// Pressure-triggered, age-gated reclamation. Retention is a minimum age:
    /// young completed records are never evicted merely to keep running.
    func ensureCapacity() throws {
        try checkpoint()
        try checkDisk(extra:policy.maximumSQLiteBytes)
        var used = try (number("PRAGMA page_count") - number("PRAGMA freelist_count"))*4096
        let threshold = databaseLimit * Int64(policy.pruneAtPercent)/100
        let diskPressure = try freeDisk(directory) < policy.minimumFreeDiskBytes + policy.maximumSQLiteBytes*2
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
        try require(used < databaseLimit * 95/100 && sqliteBytes < policy.maximumSQLiteBytes - databaseLimit,"storage pressure: SQLite budget reached; no eligible old history can free enough space")
    }
    private func snapshot() throws {
        if ready && !maintenance {try ensureCapacity()}
        if ready && sequence == snapshotSequence {return}
        let wasMaintenance=maintenance; maintenance=true
        defer {maintenance=wasMaintenance}
        try atomic {
            try execute("INSERT INTO snapshots(covered_sequence,gtids,source_file,source_position,created_at) VALUES(?,?,?,?,?)",[String(sequence),completedGTIDs.canonical,applied?.file,applied.map{String($0.position)},timestamp()])
        }
        snapshotSequence=sequence
    }
    private func insertSchema(_ table: ApplyTable,event: DecodedEvent,coordinate: BinlogCoordinate) throws -> Int64 {
        let schema=String(decoding:try JSONEncoder().encode(table),as:UTF8.self)
        let wire=String(decoding:try JSONEncoder().encode(event.wireColumns),as:UTF8.self)
        try execute("INSERT INTO schemas(identity,discovered_at,source_file,source_position,event_hash,schema_json,wire_json) VALUES(?,?,?,?,?,?,?)",[String(decoding:try JSONEncoder().encode([table.database,table.table]),as:UTF8.self),timestamp(),coordinate.file,String(coordinate.position),event.sha256,schema,wire])
        return sqlite3_last_insert_rowid(db)
    }
    func schema(_ table: ApplyTable,event: DecodedEvent,coordinate: BinlogCoordinate) throws {
        if let old=schemas[table.identity] {try require(old.1==table,"schema changed without ordered DDL");return}
        try require(schemas.count<64,"schema cache limit reached")
        schemas[table.identity]=(try insertSchema(table,event:event,coordinate:coordinate),table)
    }
    func ddlIntent(_ plan: PreparedDDL,event: DecodedEvent,coordinate: BinlogCoordinate) throws {
        try require(pendingGTID != nil,"DDL intent without pending group")
        if let before=plan.before {try schema(before,event:event,coordinate:coordinate)}
        let beforeID=plan.statement.name.flatMap{schemas[$0.identity]?.0}
        let databaseJSON=try plan.database.map{String(decoding:try JSONEncoder().encode($0),as:UTF8.self)}
        try execute("INSERT INTO ddl_intents(gtid,before_schema_id,target_sql,database_json,status,created_at) VALUES(?,?,?,?,'PENDING',?)",[pendingGTID,beforeID.map(String.init),plan.sql,databaseJSON,timestamp()])
    }
    func append(_ record: LiveRecord) throws {
        guard let encoded = record.event?.rawBase64 ?? record.rawBase64, let bytes = Data(base64Encoded:encoded) else {throw ApplyError("relay event lacks original bytes")}
        let metadata = try JSONSerialization.data(withJSONObject:["kind":record.kind,"file":record.file,"observedPosition":record.observedPosition],options:[.sortedKeys])
        var frame = Data()
        for n in [UInt32(metadata.count),UInt32(bytes.count)] {var le=n.littleEndian; withUnsafeBytes(of:&le){frame.append(contentsOf:$0)}}
        frame += metadata; frame += bytes
        try require(UInt64(frame.count) <= maximumBytes-relayLength,"relay storage limit reached")
        try checkDisk(extra:policy.maximumSQLiteBytes+Int64(frame.count))
        try relay!.write(contentsOf:frame); relayLength += UInt64(frame.count)
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
    func begin(_ group: CompleteTransaction) throws {
        guard let identity = group.gtid else {throw ApplyError("group lacks GTID")}
        try require(pendingGTID == nil && !completedGTIDs.contains(sid:identity.sid,sequence:identity.sequence),"duplicate or excluded applied GTID")
        let id=identity.sid+":"+identity.sequence
        try relay!.synchronize()
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
    func complete(_ group: CompleteTransaction,rowCount: Int,ddl: PreparedDDL? = nil) throws {
        guard let identity=group.gtid,let pendingGTID,pendingGTID==identity.sid+":"+identity.sequence,(rowCount>0 && ddl==nil) || (rowCount==0 && ddl != nil) else {throw ApplyError("completion without matching pending group")}
        let done = try query("SELECT COUNT(*) FROM row_intents WHERE gtid=? AND status='DONE'",[pendingGTID])[0][0]
        try require(Int(done ?? "") == rowCount,"cannot complete group with unfinished row intents")
        if ddl != nil {
            try require(group.outcome == .statement && (try number("SELECT COUNT(*) FROM ddl_intents WHERE status='PENDING'")) == 1,"DDL completion without a pending intent")
        }
        var newSchemaID: Int64?
        var next=completedGTIDs; try next.include(sid:identity.sid,sequence:identity.sequence)
        let time=timestamp()
        try atomic {
            if let ddl {
                if ddl.preservesSchema {newSchemaID=ddl.statement.name.flatMap{schemas[$0.identity]?.0}}
                else {
                    if let name=ddl.statement.name,let old=schemas[name.identity] {
                        try execute("UPDATE schemas SET current=0,retired_at=? WHERE id=?",[time,String(old.0)])
                    }
                    if let after=ddl.after {newSchemaID=try insertSchema(after,event:group.events[1],coordinate:group.end)}
                }
                try execute("UPDATE ddl_intents SET status='DONE',completed_at=?,after_schema_id=? WHERE gtid=?",[time,newSchemaID.map(String.init),pendingGTID])
            }
            try execute("UPDATE groups SET status='APPLIED',completed_at=? WHERE gtid=?",[time,pendingGTID])
            try execute("UPDATE state SET applied_file=?,applied_position=?,applied_sequence=?,transactions_applied=?,rows_applied=?,ddl_applied=?,active_gtid=NULL,updated_at=?,last_applied_at=? WHERE id=1",[group.end.file,String(group.end.position),String(pendingSequence),String(transactions+1),String(rows+rowCount),String(ddlApplied+(ddl == nil ? 0 : 1)),time,time])
        }
        if let ddl {
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
        try relay!.synchronize()
        if sequence != snapshotSequence {try snapshot()}
        try execute("UPDATE state SET lifecycle='STOPPED',durable_relay_length=?,updated_at=? WHERE id=1",[String(relayLength),timestamp()])
        try checkpoint()
    }
    func block(_ reason: String) throws {
        try relay!.synchronize()
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
