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

/// Separate offline path; never connects to MySQL or guesses target outcomes.
final class RecoveryStore {
    private let configuration: ApplyConfiguration
    private let directory: URL
    private var lock: FileHandle?
    private var db: OpaquePointer?
    private var sql: SQLiteStatementCache?
    private let writable: Bool
    init(configuration: ApplyConfiguration, writable: Bool) throws {
        try configuration.validate(offline:true)
        try require(configuration.replicationProfile == .mysql57To84InnoDB,"recovery currently supports only the reverse InnoDB profile")
        self.configuration = configuration; self.writable = writable
        directory = URL(fileURLWithPath:configuration.stateDirectory)
        let fd = open(directory.appendingPathComponent("writer.lock").path,O_RDWR)
        guard fd >= 0 else { throw ApplyError("existing state writer lock is required") }
        lock = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do {
            try require(flock(fd,LOCK_EX|LOCK_NB) == 0,"stop the applier before recovery; state has an active writer")
            let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
            try require(sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path,&db,flags,nil) == SQLITE_OK,"cannot open recovery state")
            sql = SQLiteStatementCache(db:db!,timings:.init(),profiling:false)
            try require(try q("PRAGMA user_version") == [["9"]],"recovery requires state format 9")
            try require(try q("PRAGMA quick_check") == [["ok"]],"recovery SQLite integrity check failed")
            try require(try q("SELECT profile FROM replication_profile WHERE id=1") == [[configuration.replicationProfile.rawValue]],"saved replication profile differs")
            let policy = try q("SELECT policy_json FROM compatibility WHERE id=1")
            guard let text = policy.first?.first ?? nil else { throw ApplyError("missing compatibility policy") }
            try require(try JSONDecoder().decode(CompatibilityPolicy.self,from:Data(text.utf8)) == configuration.compatibilityPolicy,"saved compatibility policy differs")
            if writable { _ = try q("PRAGMA synchronous=FULL") }
        } catch { sql?.close(); sql=nil; sqlite3_close(db); db=nil; try? lock?.close(); lock=nil; throw error }
    }
    deinit { sql?.close(); sqlite3_close(db); try? lock?.close() }
    private func q(_ statement: String, _ args: [String?] = []) throws -> [[String?]] { try sql!.query(statement,args) }
    private func exists(_ table: String) throws -> Bool { try !q("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",[table]).isEmpty }
    private func state() throws -> [String?] {
        let rows = try q("SELECT lifecycle,source_uuid,target_uuid,applied_file,applied_position,applied_sequence,transactions_applied,rows_applied,ddl_applied,durable_relay_length,active_gtid,diagnostic,baseline_gtids FROM state WHERE id=1")
        guard let r = rows.first, rows.count == 1 else { throw ApplyError("missing saved state") }
        try require(r[1]?.lowercased() == configuration.source.sourceUUID.lowercased(),"saved source UUID differs")
        try require(UUID(uuidString:r[2] ?? "") != nil,"missing saved target UUID")
        guard let seq=Int64(r[5] ?? ""), seq >= 0, seq < Int64.max-100000,
              let count=Int64(r[7] ?? ""), count >= 0, count < Int64.max-10000000,
              let ddl=Int64(r[8] ?? ""), ddl >= 0, ddl <= seq, r[5] == r[6] else { throw ApplyError("invalid transaction checkpoint") }
        return r
    }
    private func coverage(_ state: [String?]) throws -> GTIDSet {
        guard let checkpoint = Int64(state[5] ?? ""), checkpoint >= 0,
              let snap = try q("SELECT covered_sequence,gtids,source_file,source_position FROM snapshots ORDER BY id DESC LIMIT 1").first,
              var seq = Int64(snap[0] ?? ""), seq >= 0, seq <= checkpoint else { throw ApplyError("invalid recovery snapshot") }
        var set = try GTIDSet(snap[1] ?? ""), file = snap[2], position = snap[3]
        for r in try q("SELECT sequence,gtid,source_file,end_position FROM groups WHERE status='APPLIED' AND sequence>? ORDER BY sequence",[String(seq)]) {
            seq += 1
            try require(Int64(r[0] ?? "") == seq && seq <= checkpoint,"applied history gap")
            try include(r[1] ?? "",in:&set)
            file = r[2]; position = r[3]
        }
        try require(seq == checkpoint && file == state[3] && position == state[4],"snapshot/history differs from checkpoint")
        try require(try set.covers(GTIDSet(state[12] ?? "")),"checkpoint lost baseline GTIDs")
        return set
    }
    private func include(_ gtid: String, in set: inout GTIDSet) throws {
        let parts = gtid.split(separator:":")
        try require(parts.count == 2 && UUID(uuidString:String(parts[0])) != nil && UInt64(parts[1]) != nil,"invalid singleton GTID")
        try require(try !set.covers(GTIDSet(gtid)),"duplicate covered GTID")
        try set.include(sid:String(parts[0]),sequence:String(parts[1]))
    }
    func inspect() throws -> Recovery.Report {
        let s = try state(), covered = try coverage(s)
        guard let durable = UInt64(s[9] ?? "") else { throw ApplyError("invalid durable relay length") }
        let handle = try FileHandle(forReadingFrom:directory.appendingPathComponent("relay.frames"))
        defer { try? handle.close() }
        let actual = try handle.seekToEnd()
        try require(actual >= durable,"relay is shorter than durable checkpoint")
        try require(try q("SELECT 1 FROM row_intents r LEFT JOIN groups g ON g.gtid=r.gtid WHERE g.gtid IS NULL OR (g.status='APPLIED' AND r.status!='DONE') LIMIT 1").isEmpty,"orphan or unresolved row intent outside pending groups")
        try require(try q("SELECT 1 FROM ddl_intents WHERE status!='DONE' LIMIT 1").isEmpty,"unresolved DDL is outside this recovery profile")
        var pending: [Recovery.Group] = []
        var sequence = Int64(s[5]!)!, lastEnd: UInt64 = 0
        for r in try q("SELECT sequence,gtid,source_file,start_position,end_position,relay_start,relay_end FROM groups WHERE status='PENDING' ORDER BY sequence") {
            sequence += 1
            guard Int64(r[0] ?? "") == sequence, let id=r[1], let file=r[2], let start=r[3], let end=r[4],
                  let a=UInt64(start), let b=UInt64(end), a < b,
                  let rs=UInt64(r[5] ?? ""), let re=UInt64(r[6] ?? ""), rs >= lastEnd, rs < re, re <= durable else { throw ApplyError("invalid pending group boundaries/order") }
            try require(try !covered.covers(GTIDSet(id)),"pending GTID is already covered")
            pending.append(.init(sequence:sequence,gtid:id,file:file,startPosition:start,endPosition:end,relayStart:rs,relayEnd:re))
            lastEnd = re
        }
        try require(sequence < Int64.max-1,"recovery sequence overflow")
        try require(pending.first?.gtid == s[10],"active GTID differs from pending journal")
        try require(try q("SELECT 1 FROM groups WHERE status NOT IN ('PENDING','APPLIED') LIMIT 1").isEmpty,"unknown journal status")
        let schemas = try q("SELECT id,schema_json FROM schemas")
        var tables: [String:ApplyTable] = [:]
        for r in schemas {
            let table = try JSONDecoder().decode(ApplyTable.self,from:Data((r[1] ?? "").utf8)); try table.validate()
            tables[r[0]!] = table
        }
        var intents: [RecoveryRelay.Intent] = []
        for (index,g) in pending.enumerated() {
            try require(try q("SELECT 1 FROM ddl_intents WHERE gtid=?",[g.gtid]).isEmpty,"DDL recovery is out of scope; reconcile the schema using the original runtime")
            var expectedOrdinal = 0
            for r in try q("SELECT ordinal,status,schema_id,source_event_offset,source_row FROM row_intents WHERE gtid=? ORDER BY ordinal",[g.gtid]) {
                guard let ordinal=Int(r[0] ?? ""), ordinal == expectedOrdinal,
                      let id=r[2], let table=tables[id], let offset=r[3], let row=Int(r[4] ?? ""), row >= 0,
                      let status=r[1], ["PENDING","DONE"].contains(status) else { throw ApplyError("invalid row intent") }
                expectedOrdinal += 1
                intents.append(.init(group:index,ordinal:ordinal,status:status,schemaID:id,table:table,offset:offset,row:row))
            }
            try require(intents.contains{$0.group == index},"recovery requires journaled DML; use the existing no-intent skip command for rejected DDL")
        }
        if !pending.isEmpty { try RecoveryRelay.decode(file:directory.appendingPathComponent("relay.frames"),groups:&pending,intents:intents,tables:Array(tables.values)) }
        var failure: TargetFailureDiagnostic?
        if try exists("target_failure"), let text = try q("SELECT diagnostic_json FROM target_failure WHERE id=1").first?.first ?? nil {
            failure = try JSONDecoder().decode(TargetFailureDiagnostic.self,from:Data(text.utf8))
        }
        var audit: [Recovery.Audit] = []
        if try exists("recovery_audit") {
            audit = try q("SELECT id,action,gtids,reason,created_at FROM recovery_audit ORDER BY rowid").map { .init(id:$0[0]!,action:$0[1]!,gtids:$0[2]!,reason:$0[3]!,createdAt:$0[4]!) }
        }
        return .init(profile:configuration.replicationProfile.rawValue,lifecycle:s[0]!,sourceUUID:s[1]!,targetUUID:s[2]!,appliedGTIDSet:covered.canonical,appliedFile:s[3],appliedPosition:s[4],durableRelayLength:durable,unjournaledTailBytes:actual-durable,diagnostic:s[11],targetFailure:failure,pending:pending,audit:audit)
    }
    func resolve(action: Recovery.Action, gtids: String, reason: String) throws -> Recovery.Resolution {
        try require(writable,"recovery store is read-only")
        try require(!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && reason.utf8.count <= 4096 && !reason.contains("\0"),"resolution requires a nonempty reason, at most 4096 bytes")
        let report = try inspect(), s = try state()
        try require(["BLOCKED","RUNNING","STARTING"].contains(report.lifecycle),"resolution requires blocked or crashed state")
        let requested = try GTIDSet(gtids == "none" ? "" : gtids)
        var selected = try GTIDSet("")
        if action == .retry {
            for group in report.pending { try include(group.gtid,in:&selected) }
            try require(selected == requested,"retry must name the entire unresolved GTID set; reconcile every pending transaction first (use none only if no intents exist)")
        } else {
            guard let first = report.pending.first else { throw ApplyError("no pending transaction") }
            try include(first.gtid,in:&selected)
            try require(selected == requested,"mark-applied/skip must name exactly the earliest pending GTID")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let evidence = String(decoding:try encoder.encode(report),as:UTF8.self)
        let id = UUID().uuidString.lowercased(), time = ISO8601DateFormatter().string(from:Date())
        // The prefix referenced by SQLite was synced before target writes. Save
        // any crash tail before truncating it; either side of a crash here still
        // has the unchanged journal and all its original durable relay evidence.
        if report.unjournaledTailBytes > 0 { try preserveTail(report.durableRelayLength,id:id) }
        var next = try GTIDSet(report.appliedGTIDSet)
        var sequence = Int64(s[5]!)!, transactions = Int64(s[6]!)!, rows = Int64(s[7]!)!
        var file = s[3], position = s[4]
        let remaining = action == .retry ? [] : Array(report.pending.dropFirst())
        if action != .retry, let first=report.pending.first {
            try include(first.gtid,in:&next)
            sequence += 1; transactions += 1
            if action == .markApplied { rows += Int64(first.rows.count) }
            file=first.file; position=first.endPosition
        }
        let lifecycle = remaining.isEmpty ? "STOPPED" : "BLOCKED"
        _ = try q("BEGIN IMMEDIATE")
        do {
            _ = try q("CREATE TABLE IF NOT EXISTS recovery_audit(id TEXT PRIMARY KEY,action TEXT NOT NULL,gtids TEXT NOT NULL,reason TEXT NOT NULL,created_at TEXT NOT NULL,evidence_json TEXT NOT NULL)")
            _ = try q("INSERT INTO recovery_audit VALUES(?,?,?,?,?,?)",[id,action.rawValue,selected.canonical,reason,time,evidence])
            if action == .retry {
                _ = try q("DELETE FROM row_intents WHERE gtid IN (SELECT gtid FROM groups WHERE status='PENDING')")
                _ = try q("DELETE FROM groups WHERE status='PENDING'")
            } else {
                let gtid = report.pending[0].gtid
                _ = try q("UPDATE row_intents SET status='DONE',completed_at=? WHERE gtid=?",[time,gtid])
                _ = try q("UPDATE groups SET status='APPLIED',completed_at=? WHERE gtid=?",[time,gtid])
            }
            _ = try q("INSERT INTO snapshots(covered_sequence,gtids,source_file,source_position,created_at) VALUES(?,?,?,?,?)",[String(sequence),next.canonical,file,position,time])
            _ = try q("UPDATE state SET lifecycle=?,applied_file=?,applied_position=?,applied_sequence=?,transactions_applied=?,rows_applied=?,active_gtid=?,diagnostic=?,updated_at=? WHERE id=1",[lifecycle,file,position,String(sequence),String(transactions),String(rows),remaining.first?.gtid,remaining.isEmpty ? nil : "operator resolution required for remaining pending groups",time])
            _ = try q("COMMIT")
        } catch { _ = try? q("ROLLBACK"); throw error }
        return .init(auditID:id,action:action.rawValue,gtids:selected.canonical,lifecycle:lifecycle,resumeGTIDSet:next.canonical)
    }
    private func preserveTail(_ durable: UInt64, id: String) throws {
        let relay = try FileHandle(forUpdating:directory.appendingPathComponent("relay.frames"))
        defer { try? relay.close() }
        try relay.seek(toOffset:durable)
        let path = directory.appendingPathComponent("recovery-tail-"+id+".bin").path
        let fd = open(path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        guard fd >= 0 else { throw ApplyError("cannot preserve unjournaled relay tail") }
        let tail = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? tail.close() }
        while let data = try relay.read(upToCount:1024*1024), !data.isEmpty { try tail.write(contentsOf:data) }
        try tail.synchronize(); try StateStore.syncDirectory(directory)
        try relay.truncate(atOffset:durable); try relay.synchronize()
    }
}
