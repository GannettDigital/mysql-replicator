import Foundation

/// Public option names and help. The example/model test checks this catalog for
/// missing and obsolete settings. Values still use the normal typed decoder.
public enum ConfigurationOptions {
    public static let descriptions: [String: String] = [
        "applierProfiling": "Detailed apply timings; coarse timings stay on.",
        "archive": "Required for fetch and replay. Optional for support bundles. Binary log files; ignored by run.",
        "archive.directory": "Required. fetch: must NOT exist; replay: existing immutable raw binlogs.",
        "archive.files": "Optional ordered, nonempty list for EXTERNAL replay only; rejected by fetch.",
        "archive.firstFile":
            "Whole starting file. fetch defaults to source.start.file or the oldest source file. External replay defaults to the first selected file.",
        "archive.lowerCaseTableNames":
            "Optional original source setting for EXTERNAL archives. Must match source.lowerCaseTableNames (default 0).",
        "archive.maximumBytes": "Default 64 GiB total archive limit; minimum 4 bytes. Increase for multi-day archives.",
        "batch": "Prepare and apply bounded groups of source transactions.",
        "batch.flushOnTableChange": "true ends a batch whenever its table changes.",
        "batch.maximumDelayMilliseconds": "Flush nonempty batch after 1..1000 ms.",
        "batch.maximumInsertBytes":
            "INSERT grouping budget: 1 KiB..4 MiB. One larger row is allowed; target max_allowed_packet still applies.",
        "batch.maximumInsertRows": "Compatible rows per INSERT; 1..128.",
        "batch.maximumPreparedBatches":
            "Durable batches outstanding, including execution; 1..16. Requires overlapPreparation.",
        "batch.maximumRows": "Collection threshold; 1..65536 rows.",
        "batch.maximumTransactions": "Complete source groups per batch; 1..256.",
        "batch.maximumWireBytes": "8 MiB collection threshold; 1 KiB..32 MiB.",
        "batch.overlapPreparation": "Prepare and journal ahead while the single target worker runs.",
        "compatibility": "Optional rules for differences between source and target.",
        "compatibility.collations": "Map source collation names to supported target names.",
        "compatibility.jsonYearToInteger":
            "Only mysql57-to-mysql84-innodb. Convert YEAR inside JSON to UNSIGNED INTEGER.",
        "ddlPolicy": "Rules for source DDL that can cause independent target writes.",
        "ddlPolicy.events": "Reject source events to prevent scheduled target writes.",
        "ddlPolicy.triggers": "skip audits CREATE/DROP without issuing them. Source trigger row effects still apply.",
        "ddlTimeoutSeconds": "Top-level setting; 1..86400 seconds. Timeout can leave uncertain DDL.",
        "maximumCachedTables":
            "Schema cache and saved-schema limit; 1..100000 tables, default 6000. Applies to discovery, DDL, reload, and capture. Restart to change it.",
        "maximumRelayBytes": "Durable relay cap for run/replay; 1 MiB..1 GiB, default 256 MiB.",
        "profile": "Select the source version and target version/engine.",
        "replicateWildDoTable": "Include matching tables. Empty means all tables, subject to ignore rules.",
        "replicateWildIgnoreTable":
            "Exclude matching tables. Empty means no exclusions.",
        "skipErrors": "Optional rules to skip supported failures in run and replay.",
        "skipErrors.codes": "Example; 1062 needs confirmed InnoDB rollback.",
        "skipErrors.recordSkippedTransactions": "false keeps counters/checkpoint but no per-GTID audit.",
        "source": "Source connection and binary log settings.",
        "source.caFile": "Required for verify-ca; otherwise omit to use system trust roots.",
        "source.decoderProfiling": "Detailed decoder timings; coarse timings stay on.",
        "source.downloadCacheBytes":
            "Normal live backlog; 20 MiB..1 GiB. One larger event can enter an empty cache. Unused by replay.",
        "source.host": "Source TCP address. Use 127.0.0.1 for a local server.",
        "source.idleTimeoutSeconds": "Live source read/heartbeat timeout; 1..300 seconds.",
        "source.lowerCaseTableNames":
            "0: exact table names; 1: native lowercase names. Both servers must match. Mode 2 is not qualified.",
        "source.maximumEventBytes": "64 MiB per complete event; 23 bytes..1 GiB. Also applies to replay.",
        "source.maximumTransactionBytes":
            "256 MiB of binlog data per transaction; event limit..1 GiB. Retained-data budget is four times this value.",
        "source.mode": "run: gtid; file-position only for an 8.4 source. replay: gtid only.",
        "source.nonBlocking": "Live capture only: true exits at source EOF instead of following new writes.",
        "source.password": "Alternative; remove passwordEnvironment. Choose exactly one for run/fetch.",
        "source.passwordEnvironment": "Name of an environment variable, not its value.",
        "source.port": "Required; valid range 1..65535.",
        "source.requireTLS": "false disables TLS. Remove serverHostname and caFile when false.",
        "source.serverHostname": "Name verified against the source TLS certificate.",
        "source.serverID": "Example client ID; required nonzero UInt32, unique for live capture.",
        "source.sourceUUID": "Required original source server_uuid; also identifies the archive.",
        "source.start": "Source position that matches the initial data copy.",
        "source.start.executedGTIDs":
            "Required FULL source GTID set represented by the snapshot, not just its last GTID. Empty: \"\".",
        "source.start.file": "Example; file and position must be supplied together.",
        "source.start.position": "Example next-event byte offset; minimum 4. Required for file-position mode.",
        "source.stopAfterGTIDs": "Example inclusive GTID-set limit, not a count.",
        "source.stopAfterTransactions":
            "Example limit, 1..1000000 source groups per invocation (including DDL/filtered groups).",
        "source.tlsVerification":
            "Same choices as target: verify-identity or verify-ca. verify-ca requires caFile; serverHostname is optional.",
        "source.username": "Example account; source replication/metadata privileges.",
        "source.version": "Use version 2. Legacy source.tables is not accepted by run/replay.",
        "sourceReconnect": "Retry source connections after supported transport failures.",
        "sourceReconnect.enabled": "Live run only; replay always disables source reconnect.",
        "sourceReconnect.initialDelaySeconds": "First retry delay; 1..300 seconds.",
        "sourceReconnect.maximumAttempts": "0 = unlimited; otherwise 1..10000 since applied progress.",
        "sourceReconnect.maximumDelaySeconds": "Backoff cap; initialDelaySeconds..300 seconds.",
        "stateDirectory": "Required for run/replay/support-bundle/ctl; new with --initialize.",
        "statistics": "Status rates and live source metadata polling; replay never polls the source.",
        "statistics.tableDetails":
            "Collect bounded table statistics; default false. Restart to change. Applied counts share checkpoint commits.",
        "statistics.maximumTableEntries":
            "1 through 100000 named entries; default 6000. Warn at the limit; additional names use overflow totals.",
        "statistics.snapshotIntervalSeconds":
            "5 through 3600 seconds; save process statistics at the next completion commit, and on stop or block.",
        "statistics.rateWindowSeconds": "5 through 3600 seconds; rolling window for progress estimates.",
        "statistics.sourcePollIntervalSeconds": "5 through 3600 seconds; uses a separate source connection.",
        "storage": "SQLite capacity, history retention, and disk reserve.",
        "storage.capacityCheckEveryTransactions": "Inspect every 1..10000 groups, earlier under pressure.",
        "storage.capacityCheckIntervalSeconds": "Inspect while active every 1..60 seconds.",
        "storage.historyRetentionSeconds": "Minimum history age; 1..31536000 seconds, includes skip audit.",
        "storage.maximumSQLiteBytes": "256 MiB including WAL/headroom; 8 MiB..1 GiB.",
        "storage.minimumFreeDiskBytes": "512 MiB reserve; minimum 1 MiB.",
        "storage.pruneAtPercent": "Prune eligible history at 50..90% utilization.",
        "storage.snapshotEveryTransactions": "Covering GTID snapshot interval; 1..10000 groups.",
        "supportBundle": "Manual collection and automatic collection on a BLOCKED error.",
        "supportBundle.binlogContextBytes":
            "Maximum payload bytes per binlog excerpt; 4 KiB through 256 MiB. Original offsets are recorded.",
        "supportBundle.directory":
            "Required when onBlocked is true. Manual collection defaults to support-bundles beside stateDirectory. Must be outside stateDirectory.",
        "supportBundle.format": "tar packs the files. directory leaves them unpacked for inspection.",
        "supportBundle.logs": "Optional existing log files; omitted/[] adds no logs.",
        "supportBundle.maximumBytes": "Default 2 GiB including tar overhead; minimum 1 MiB.",
        "supportBundle.onBlocked": "true collects one bundle when run/replay enters BLOCKED.",
        "supportBundle.output":
            "Manual path. If omitted, generate a unique name in directory. Must be new and outside stateDirectory. Automatic collection always generates a name.",
        "target": "Dedicated replica connection and session settings.",
        "target.caFile": "Required for verify-ca; otherwise may be omitted for system trust roots.",
        "target.transport":
            "DML transport: sql (default) or binlog. BINLOG requires additional privileges and a new state directory; see docs/BINLOG_TRANSPORT.md.",
        "target.explicitTableLocks": "Optional LOCK TABLES; must stay false for the InnoDB profile.",
        "target.host": "Required with port unless unixSocket is set. Dedicated target matching the selected profile.",
        "target.nativeAutoStartDisabled": "Required attestation that native replication will not auto-start.",
        "target.password": "Alternative; remove passwordEnvironment. Choose exactly one.",
        "target.passwordEnvironment": "Name of the environment variable with the target password.",
        "target.port": "Required with host; valid range 1..65535.",
        "target.preserveSourceGTIDs":
            "Default. Retain source GTIDs on the target. False keeps them only in the replicator.",
        "target.requireTLS": "false disables TLS for TCP or a Unix socket.",
        "target.serverHostname": "Name to check against the target TLS certificate.",
        "target.tlsVerification": "Default: verify CA chain and serverHostname.",
        "target.unixSocket": "Example local alternative; remove both host and port.",
        "target.username": "Example account; DML/DDL and metadata visibility privileges.",
        "targetReconnect": "Retry target connections when it is safe to do so.",
        "targetReconnect.enabled": "run and replay: safe reconnects only; uncertain writes still block.",
        "targetReconnect.initialDelaySeconds": "First retry delay; 1..300 seconds.",
        "targetReconnect.maximumAttempts": "0 = unlimited; otherwise 1..10000; applied progress resets the budget.",
        "targetReconnect.maximumDelaySeconds": "Backoff cap; initialDelaySeconds..300 seconds.",
        "version": "Required config format; do not add tables/schema allowlists.",
    ]
}
