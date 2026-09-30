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

/// New-state-only journal. It deliberately provides no recovery/reopen path yet.
/// Original event bytes live in framed relay files, never SQLite payload columns.
final class StateStore {
    private var db: OpaquePointer?
    private var relay: FileHandle?
    private(set) var relayLength: UInt64 = 0
    private var groupStart: UInt64 = 0
    private var completedGTIDs: GTIDSet
    private(set) var transactions: Int = 0
    private(set) var rows: Int = 0
    private(set) var applied: BinlogCoordinate?
    private(set) var pendingGTID: String?
    let directory: URL
    let maximumBytes: UInt64
    init(configuration c: ApplyConfiguration) throws {
        directory = URL(fileURLWithPath:c.stateDirectory).standardizedFileURL
        maximumBytes = c.maximumRelayBytes ?? 256*1024*1024
        completedGTIDs = try GTIDSet(c.source.start.executedGTIDs)
        // mkdir itself provides exclusive initialization; an existence check
        // followed by createDirectory would race with another process.
        guard mkdir(directory.path,0o700) == 0 else { throw ApplyError("state directory must be new; reopen/resume is not implemented") }
        do {
            try Self.syncDirectory(directory.deletingLastPathComponent())
            let raw = directory.appendingPathComponent("relay.frames")
            let fd = open(raw.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
            guard fd >= 0 else { throw ApplyError("cannot create relay file") }
            relay = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw ApplyError("cannot create SQLite state") }
            sqlite3_busy_timeout(db,1000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1), lifecycle TEXT NOT NULL, source_uuid TEXT NOT NULL, target_uuid TEXT NOT NULL, baseline_file TEXT, baseline_position TEXT, baseline_gtids TEXT NOT NULL, schema_json TEXT NOT NULL, applied_file TEXT, applied_position TEXT, applied_gtids TEXT NOT NULL, transactions_applied INTEGER NOT NULL DEFAULT 0, rows_applied INTEGER NOT NULL DEFAULT 0, durable_relay_length INTEGER NOT NULL DEFAULT 0, active_gtid TEXT, updated_at TEXT NOT NULL, diagnostic TEXT)")
            try execute("CREATE TABLE groups(gtid TEXT PRIMARY KEY, source_file TEXT NOT NULL, start_position TEXT NOT NULL, end_position TEXT NOT NULL, relay_start INTEGER NOT NULL, relay_end INTEGER NOT NULL, status TEXT NOT NULL)")
            try execute("CREATE TABLE row_intents(gtid TEXT NOT NULL, ordinal INTEGER NOT NULL, source_event_offset TEXT NOT NULL, source_row INTEGER NOT NULL, status TEXT NOT NULL, PRIMARY KEY(gtid,ordinal))")
            let schema = String(decoding:try JSONEncoder().encode(c.tables),as:UTF8.self)
            try execute("INSERT INTO state(id,lifecycle,source_uuid,target_uuid,baseline_file,baseline_position,baseline_gtids,schema_json,applied_gtids,updated_at) VALUES(1,'STARTING',?,?,?,?,?,?,?,?)",[c.source.sourceUUID,c.target.targetUUID,c.source.start.file,c.source.start.position.map(String.init),completedGTIDs.canonical,schema,completedGTIDs.canonical,Self.timestamp()])
            try Self.syncDirectory(directory)
        } catch { sqlite3_close(db); db = nil; try? relay?.close(); relay = nil; throw error }
    }
    deinit { try? relay?.close(); sqlite3_close(db) }
    static func timestamp() -> String { ISO8601DateFormatter().string(from:Date()) }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path,O_RDONLY)
        guard fd >= 0 else { throw ApplyError("cannot open state directory for synchronization") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ApplyError("cannot synchronize state directory") }
    }
    private func execute(_ sql: String, _ args: [String?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { throw ApplyError("SQLite statement preparation failed") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (i,value) in args.enumerated() {
            let rc = value.map { sqlite3_bind_text(stmt,Int32(i+1),$0,-1,transient) } ?? sqlite3_bind_null(stmt,Int32(i+1))
            guard rc == SQLITE_OK else { throw ApplyError("SQLite bind failed") }
        }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw ApplyError("SQLite state write failed (code \(rc))") }
    }
    private func atomic(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func append(_ record: LiveRecord) throws {
        guard let encoded = record.event?.rawBase64 ?? record.rawBase64, let bytes = Data(base64Encoded:encoded) else { throw ApplyError("relay event lacks original bytes") }
        let metadata = try JSONSerialization.data(withJSONObject:["kind":record.kind,"file":record.file,"observedPosition":record.observedPosition],options:[.sortedKeys])
        var header = Data()
        for n in [UInt32(metadata.count),UInt32(bytes.count)] { var le = n.littleEndian; withUnsafeBytes(of:&le) { header.append(contentsOf:$0) } }
        let frame = header + metadata + bytes
        try require(UInt64(frame.count) <= maximumBytes-relayLength,"relay storage limit reached")
        try relay!.write(contentsOf:frame); relayLength += UInt64(frame.count)
    }
    func running() throws { try execute("UPDATE state SET lifecycle='RUNNING',updated_at=? WHERE id=1",[Self.timestamp()]) }
    func begin(_ group: CompleteTransaction) throws {
        guard let identity = group.gtid else { throw ApplyError("group lacks GTID") }
        try require(!completedGTIDs.contains(sid:identity.sid,sequence:identity.sequence),"duplicate or excluded applied GTID")
        let id = identity.sid + ":" + identity.sequence
        try relay!.synchronize()
        try atomic {
            try execute("INSERT INTO groups VALUES(?,?,?,?,?,?,'PENDING')",[id,group.start.file,String(group.start.position),String(group.end.position),String(groupStart),String(relayLength)])
            try execute("UPDATE state SET active_gtid=?,durable_relay_length=?,updated_at=? WHERE id=1",[id,String(relayLength),Self.timestamp()])
        }
        pendingGTID = id
    }
    func intent(_ ordinal: Int, _ mutation: Mutation) throws {
        try execute("INSERT INTO row_intents VALUES(?,?,?,?,'PENDING')",[pendingGTID,String(ordinal),mutation.eventOffset,String(mutation.rowIndex)])
    }
    func rowDone(_ ordinal: Int) throws {
        try execute("UPDATE row_intents SET status='DONE' WHERE gtid=? AND ordinal=?",[pendingGTID,String(ordinal)])
    }
    private func completedIntentCount(_ id: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM row_intents WHERE gtid=? AND status='DONE'",-1,&stmt,nil) == SQLITE_OK else { throw ApplyError("cannot verify completed intents") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt,1,id,-1,transient) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw ApplyError("cannot read completed intents") }
        return Int(sqlite3_column_int64(stmt,0))
    }
    func complete(_ group: CompleteTransaction, rowCount: Int) throws {
        guard let identity = group.gtid, let pendingGTID,
              pendingGTID == identity.sid + ":" + identity.sequence, rowCount > 0 else { throw ApplyError("completion without matching pending group") }
        try require(try completedIntentCount(pendingGTID) == rowCount,"cannot complete group with unfinished row intents")
        var next = completedGTIDs
        try next.include(sid:group.gtid!.sid,sequence:group.gtid!.sequence)
        try atomic {
            try execute("UPDATE groups SET status='APPLIED' WHERE gtid=?",[pendingGTID])
            try execute("UPDATE state SET applied_file=?,applied_position=?,applied_gtids=?,transactions_applied=?,rows_applied=?,active_gtid=NULL,updated_at=? WHERE id=1",[group.end.file,String(group.end.position),next.canonical,String(transactions+1),String(rows+rowCount),Self.timestamp()])
        }
        completedGTIDs = next; applied = group.end; transactions += 1; rows += rowCount; self.pendingGTID = nil; groupStart = relayLength
    }
    func stopped() throws {
        try relay!.synchronize()
        try execute("UPDATE state SET lifecycle='STOPPED',durable_relay_length=?,updated_at=? WHERE id=1",[String(relayLength),Self.timestamp()])
    }
    func block(_ reason: String) throws {
        try relay!.synchronize()
        try execute("UPDATE state SET lifecycle='BLOCKED',diagnostic=?,durable_relay_length=?,updated_at=? WHERE id=1",[String(reason.prefix(4096)),String(relayLength),Self.timestamp()])
    }
    var gtids: String { completedGTIDs.canonical }
}
