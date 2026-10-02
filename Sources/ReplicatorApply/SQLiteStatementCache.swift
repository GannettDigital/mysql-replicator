import Foundation
import CSQLite
import ReplicatorCodec

/// Serial, connection-local cache. The owner must close it before closing SQLite.
/// Every retained statement is idle with no bindings between calls. Errors evict
/// the statement and propagate to the journal's existing rollback/block path.
final class SQLiteStatementCache {
    private final class Entry {
        let statement: OpaquePointer
        var used: UInt64
        init(_ statement: OpaquePointer, used: UInt64) { self.statement=statement; self.used=used }
    }
    private let db: OpaquePointer
    private let capacity: Int
    private let timings: StageTimings
    private let profiling: Bool
    private var entries: [String:Entry] = [:]
    private var generation: UInt64 = 0
    private var closed = false
    var count: Int { entries.count }

    init(db: OpaquePointer, capacity: Int = 64, timings: StageTimings, profiling: Bool) {
        precondition(capacity >= 0)
        self.db=db; self.capacity=capacity; self.timings=timings; self.profiling=profiling
    }
    deinit { close() }
    private func profile<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        if !profiling { return try body() }
        return try timings.measure("apply.detail.sqlite."+stage,body)
    }
    private func finalize(_ statement: OpaquePointer) {
        _ = profile("finalize") { sqlite3_finalize(statement) }
    }
    func close() {
        for entry in entries.values { finalize(entry.statement) }
        entries.removeAll(); closed=true
    }
    // PRAGMAs may have prepare-time effects. DDL/maintenance statements are
    // infrequent and remain single-use. Cache keys are complete, internal SQL.
    private func reusable(_ sql: String) -> Bool {
        capacity > 0 && (["SELECT ","INSERT ","UPDATE ","DELETE "].contains { sql.hasPrefix($0) }
            || ["BEGIN IMMEDIATE","COMMIT","ROLLBACK"].contains(sql))
    }
    func query(_ sql: String, _ args: [String?] = []) throws -> [[String?]] {
        try require(!closed,"SQLite statement cache is closed")
        generation &+= 1
        let statement: OpaquePointer
        let cached: Bool
        if let entry=entries[sql] {
            statement=profile("cache_hit") { entry.used=generation; return entry.statement }
            cached=true
        } else {
            statement=try profile("prepare") {
                var prepared: OpaquePointer?
                let rc=sqlite3_prepare_v2(db,sql,-1,&prepared,nil)
                guard rc == SQLITE_OK, let result=prepared else {
                    if let prepared { finalize(prepared) }
                    throw ApplyError("SQLite preparation failed")
                }
                return result
            }
            cached=reusable(sql)
            if cached {
                if entries.count == capacity, let oldest=entries.min(by: { $0.value.used < $1.value.used }) {
                    entries.removeValue(forKey:oldest.key)
                    profile("cache_evict") { finalize(oldest.value.statement) }
                }
                entries[sql]=Entry(statement,used:generation)
            }
        }
        var retain=false
        defer {
            if !retain {
                if cached { entries.removeValue(forKey:sql) }
                finalize(statement)
            }
        }
        try profile("bind") {
            let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            for (i,arg) in args.enumerated() {
                let rc=arg.map { sqlite3_bind_text(statement,Int32(i+1),$0,-1,transient) } ?? sqlite3_bind_null(statement,Int32(i+1))
                try require(rc == SQLITE_OK,"SQLite bind failed")
            }
        }
        let output: [[String?]] = try profile("step") {
            var rows: [[String?]] = []
            var rc=sqlite3_step(statement)
            while rc == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { i in sqlite3_column_text(statement,i).map { String(cString:$0) } })
                rc=sqlite3_step(statement)
            }
            try require(rc == SQLITE_DONE,"SQLite operation failed (code \(rc)); replication stopped")
            return rows
        }
        if cached {
            try profile("reset") { try require(sqlite3_reset(statement) == SQLITE_OK,"SQLite reset failed; replication stopped") }
            try profile("clear_bindings") { try require(sqlite3_clear_bindings(statement) == SQLITE_OK,"SQLite clear bindings failed") }
            retain=true
        }
        return output
    }
}
