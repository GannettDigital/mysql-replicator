import Foundation

/// Optional, disposable-fixture instrumentation. Nested timers are not additive.
/// User summaries retain the target session's counters after it disconnects.
enum ServerSQLProfile {
    typealias Metric = ServerWorkCounters.Metric
    typealias Snapshot = [String:Metric]

    static func enable(_ f: LabFixture, role: LabProfile.Role) throws {
        try require(try f.sql(role,"SELECT @@performance_schema") == "1", "Performance Schema is disabled")
        _ = try f.sql(role,"""
            UPDATE performance_schema.setup_instruments SET ENABLED='YES',TIMED='YES'
              WHERE NAME LIKE 'statement/%' OR NAME LIKE 'stage/sql/%' OR NAME LIKE 'wait/%' OR NAME='transaction';
            UPDATE performance_schema.setup_consumers SET ENABLED='YES'
              WHERE NAME IN ('global_instrumentation','thread_instrumentation','events_statements_current','events_stages_current','events_waits_current','events_transactions_current');
            UPDATE performance_schema.threads SET INSTRUMENTED='YES';
            """)
        let settings=try f.sql(role,"SELECT NAME,ENABLED,TIMED FROM performance_schema.setup_instruments WHERE ENABLED='YES' ORDER BY NAME; SELECT NAME,ENABLED FROM performance_schema.setup_consumers ORDER BY NAME")
        try settings.write(to:f.output.appendingPathComponent("server-profile-"+role.rawValue+"-instruments.tsv"),atomically:true,encoding:.utf8)
    }

    static func capture(_ f: LabFixture, role: LabProfile.Role) throws -> Snapshot {
        let native = role == .native
        let scope = native ? "by_thread" : "by_user"
        let predicate = native
            ? "THREAD_ID IN (SELECT THREAD_ID FROM performance_schema.threads WHERE NAME IN ('thread/sql/replica_sql','thread/sql/slave_sql','thread/sql/replica_worker','thread/sql/slave_worker'))"
            : "USER='apply_fixture'"
        var queries: [String] = []
        for category in ["statements","stages","waits","transactions"] {
            queries.append("SELECT JSON_OBJECT('key',CONCAT('foreground.\(category).',EVENT_NAME),'count',SUM(COUNT_STAR),'picoseconds',SUM(SUM_TIMER_WAIT)) FROM performance_schema.events_\(category)_summary_\(scope)_by_event_name WHERE \(predicate) GROUP BY EVENT_NAME")
        }
        // Global file counters include work performed by background redo threads.
        // MISC includes sync, open, close, etc.; it is not an fsync-only timer.
        for operation in ["READ","WRITE","MISC"] {
            queries.append("SELECT JSON_OBJECT('key',CONCAT('global.file.\(operation.lowercased()).',EVENT_NAME),'count',COUNT_\(operation),'picoseconds',SUM_TIMER_\(operation)) FROM performance_schema.file_summary_by_event_name")
        }
        queries.append("SELECT JSON_OBJECT('key',CONCAT('background.waits.',t.NAME,'.',w.EVENT_NAME),'count',SUM(w.COUNT_STAR),'picoseconds',SUM(w.SUM_TIMER_WAIT)) FROM performance_schema.events_waits_summary_by_thread_by_event_name w JOIN performance_schema.threads t USING(THREAD_ID) WHERE t.TYPE='BACKGROUND' AND t.NAME LIKE 'thread/innodb/%' GROUP BY t.NAME,w.EVENT_NAME")
        queries.append("SELECT JSON_OBJECT('key',CONCAT('foreground.status.',VARIABLE_NAME),'count',CAST(SUM(VARIABLE_VALUE) AS UNSIGNED),'picoseconds',0) FROM performance_schema.status_\(scope) WHERE \(predicate) AND (VARIABLE_NAME LIKE 'Handler_%' OR VARIABLE_NAME IN ('Com_stmt_prepare','Com_stmt_execute','Com_stmt_reprepare','Com_insert','Com_update','Com_delete','Com_commit','Com_rollback','Opened_tables','Opened_table_definitions')) GROUP BY VARIABLE_NAME")
        queries.append("SELECT JSON_OBJECT('key',CONCAT('table.',OBJECT_NAME),'count',COUNT_STAR,'picoseconds',SUM_TIMER_WAIT) FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='reverse_poc'")
        let raw=try f.sql(role,queries.joined(separator:"; "))
        var result: Snapshot = [:]
        for line in raw.split(separator:"\n") {
            let metric=try JSONDecoder().decode(Metric.self,from:Data(line.utf8))
            try require(result.updateValue(metric,forKey:metric.key) == nil,"duplicate SQL profile metric")
        }
        return result
    }

    static func delta(before: Snapshot, after: Snapshot) throws -> Snapshot {
        // Native is stopped before the baseline and started with a fresh SQL
        // thread. Target uses persistent user aggregates across connection exit.
        try ServerWorkCounters.delta(before:.init(threadIDs:[],metrics:before),after:.init(threadIDs:[],metrics:after))
    }

    static func save(_ f: LabFixture, role: LabProfile.Role, before: Snapshot, after: Snapshot) throws {
        let delta=try delta(before:before,after:after)
        let prefix="server-profile-"+role.rawValue
        let scope="Foreground: native SQL/worker threads or target apply_fixture user (survives disconnect). Files: whole isolated server. Background: InnoDB threads, including idle waits. Timers overlap; do not sum categories. MISC file operations are not exclusively fsync."
        try writeJSON(["scope":scope,"before":before.mapValues { ["count":$0.count,"picoseconds":$0.picoseconds] },"after":after.mapValues { ["count":$0.count,"picoseconds":$0.picoseconds] },"delta":delta.mapValues { ["count":$0.count,"picoseconds":$0.picoseconds] }],to:f.output.appendingPathComponent(prefix+".json"))
        let rows=delta.values.filter { $0.count > 0 || $0.picoseconds > 0 }.sorted {
            $0.picoseconds == $1.picoseconds ? $0.key < $1.key : $0.picoseconds > $1.picoseconds
        }.map { "\($0.key)\t\($0.count)\t\(Double($0.picoseconds)/1e12)\t\($0.count == 0 ? 0 : Double($0.picoseconds)/Double($0.count)/1e9)" }
        try ("metric\tcount\tseconds\tmean_ms\n"+rows.joined(separator:"\n")+"\n").write(to:f.output.appendingPathComponent(prefix+".tsv"),atomically:true,encoding:.utf8)
        try require(delta.contains { $0.key.hasPrefix("foreground.waits.wait/io/table/") && $0.value.count > 0 && $0.value.picoseconds > 0 },"missing foreground table instrumentation for "+role.rawValue)
        // MyISAM writes do not necessarily register a transaction instrument.
        if f.profile.transactionalTarget {
            try require(delta.contains { $0.key.hasPrefix("foreground.transactions.") && $0.value.count > 0 && $0.value.picoseconds > 0 },"missing foreground transaction instrumentation for "+role.rawValue)
        }
    }
}
