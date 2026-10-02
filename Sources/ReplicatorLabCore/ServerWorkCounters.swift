import Foundation

/// Read-only fixture observations. Table counters are handler operations, not
/// SQL statements, physical disk I/O, or a claim that native apply does no work.
enum ServerWorkCounters {
    struct Metric: Codable, Equatable {
        let key: String
        let count: UInt64
        let picoseconds: UInt64
    }
    struct Snapshot: Codable {
        let threadIDs: [UInt64]
        let metrics: [String:Metric]
    }
    static func delta(before: Snapshot, after: Snapshot) throws -> [String:Metric] {
        try require(before.threadIDs == after.threadIDs,"replica instrumentation threads changed during benchmark")
        var result: [String:Metric] = [:]
        for (key,old) in before.metrics where old.count > 0 || old.picoseconds > 0 {
            try require(after.metrics[key] != nil,"server counter disappeared: " + key)
        }
        for (key,new) in after.metrics {
            let old=before.metrics[key]
            try require(new.count >= (old?.count ?? 0) && new.picoseconds >= (old?.picoseconds ?? 0),"server counter reset: " + key)
            result[key]=Metric(key:key,count:new.count-(old?.count ?? 0),picoseconds:new.picoseconds-(old?.picoseconds ?? 0))
        }
        return result
    }
    static func capture(_ h: NativeHarness, service: String) throws -> Snapshot {
        let predicate = service == "target57" ? "PROCESSLIST_USER='apply_fixture'"
            : "NAME IN ('thread/sql/replica_sql','thread/sql/slave_sql','thread/sql/replica_worker','thread/sql/slave_worker')"
        let ids=try h.sql(service,"SELECT THREAD_ID FROM performance_schema.threads WHERE \(predicate) ORDER BY THREAD_ID")
            .split(separator:"\n").compactMap{UInt64($0)}
        try require(!ids.isEmpty,"no instrumented applier threads on " + service)
        let list=ids.map(String.init).joined(separator:",")
        try require(h.sql(service,"SELECT COUNT(*) FROM performance_schema.threads WHERE THREAD_ID IN (\(list)) AND INSTRUMENTED='NO'") == "0","applier thread instrumentation is disabled")
        try require(h.sql(service,"SELECT COUNT(*) FROM performance_schema.setup_consumers WHERE NAME IN ('global_instrumentation','thread_instrumentation','events_statements_current') AND ENABLED='YES'") == "3","statement instrumentation consumers are disabled")
        try require(h.sql(service,"SELECT COUNT(*) FROM performance_schema.setup_instruments WHERE NAME IN ('wait/io/table/sql/handler','statement/sql/select','statement/sql/insert') AND ENABLED='YES'") == "3","required SQL/table instrumentation is disabled")
        let statements = "SELECT JSON_OBJECT('key',CONCAT('statement.',EVENT_NAME),'count',SUM(COUNT_STAR),'picoseconds',SUM(SUM_TIMER_WAIT)) FROM performance_schema.events_statements_summary_by_thread_by_event_name WHERE THREAD_ID IN (\(list)) GROUP BY EVENT_NAME"
        let prepared = "SELECT JSON_OBJECT('key',CONCAT('prepared.',SQL_TEXT),'count',SUM(COUNT_EXECUTE),'picoseconds',SUM(SUM_TIMER_EXECUTE)) FROM performance_schema.prepared_statements_instances WHERE OWNER_THREAD_ID IN (\(list)) GROUP BY SQL_TEXT"
        let status = "SELECT JSON_OBJECT('key',CONCAT('status.',VARIABLE_NAME),'count',CAST(SUM(VARIABLE_VALUE) AS UNSIGNED),'picoseconds',0) FROM performance_schema.status_by_thread WHERE THREAD_ID IN (\(list)) AND (VARIABLE_NAME LIKE 'Handler_%' OR VARIABLE_NAME IN ('Com_stmt_prepare','Com_stmt_execute','Com_select','Com_insert','Com_update','Com_delete','Com_lock_tables','Com_unlock_tables','Opened_tables','Opened_table_definitions')) GROUP BY VARIABLE_NAME"
        var queries=[statements,prepared,status]
        for operation in ["FETCH","INSERT","UPDATE","DELETE"] {
            queries.append("SELECT JSON_OBJECT('key','table.\(operation.lowercased())','count',COUNT_\(operation),'picoseconds',SUM_TIMER_\(operation)) FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='demo' AND OBJECT_NAME='bench'")
        }
        queries.append("SELECT JSON_OBJECT('key','table.lock','count',COUNT_STAR,'picoseconds',SUM_TIMER_WAIT) FROM performance_schema.table_lock_waits_summary_by_table WHERE OBJECT_SCHEMA='demo' AND OBJECT_NAME='bench'")
        let raw=try h.sql(service,queries.joined(separator:"; "))
        var metrics: [String:Metric] = [:]
        for line in raw.split(separator:"\n") {
            let metric=try JSONDecoder().decode(Metric.self,from:Data(line.utf8))
            try require(metrics.updateValue(metric,forKey:metric.key) == nil,"duplicate server metric")
        }
        try require(metrics["table.insert"] != nil && metrics["table.fetch"] != nil,"missing benchmark table instrumentation")
        return Snapshot(threadIDs:ids,metrics:metrics)
    }
}
