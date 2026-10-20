import Foundation

/// Documentation metadata. Runtime validation remains in the configuration models.
/// Tests compare these types and defaults with those models.
public struct ConfigurationOptionMetadata {
    public enum ValueType: String {
        case string = "STRING", integer = "INTEGER", boolean = "BOOLEAN", enumeration = "ENUM"
        case stringList = "STRING_LIST", stringMap = "STRING_MAP", section = "SECTION"
    }
    public let type: ValueType
    public let required: Bool
    public let nullable: Bool
    /// A YAML value, or nil when the caller must supply a value or no value is set.
    public let defaultValue: String?
    public let example: String
    public let allowedValues: [String]
    public let units: String?
    public let commands: Set<String>
}

extension ConfigurationOptions {
    public static let commands: Set<String> = [
        "run", "replay", "fetch", "support-bundle", "ctl", "recovery", "skip", "blackhole", "inspect",
    ]

    public static let metadata: [String: ConfigurationOptionMetadata] = {
        var result: [String: ConfigurationOptionMetadata] = [:]
        func add(
            _ names: String, _ type: ConfigurationOptionMetadata.ValueType,
            default value: String? = nil, example: String? = nil, required: Bool = false,
            allowed: [String] = [], units: String? = nil
        ) {
            for name in names.split(separator: " ").map(String.init) {
                result[name] = .init(
                    type: type, required: required, nullable: !required, defaultValue: value,
                    example: example ?? value ?? "''", allowedValues: allowed, units: units,
                    commands: applicableCommands(name))
            }
        }
        add("source target source.start", .section, example: "{}", required: true)
        add(
            "archive batch compatibility ddlPolicy skipErrors sourceReconnect targetReconnect statistics storage supportBundle",
            .section, example: "{}")
        add("version source.version", .integer, example: "2", required: true, allowed: ["2"])
        add("stateDirectory", .string, example: "./replica-state", required: true)
        add(
            "profile", .enumeration, default: "mysql84-to-mysql57-myisam",
            allowed: [
                "mysql84-to-mysql57-myisam", "mysql57-to-mysql84-innodb", "mysql57-to-mysql57-myisam",
                "mysql57-to-mysql57-innodb",
            ])
        add(
            "applierProfiling source.decoderProfiling source.nonBlocking compatibility.jsonYearToInteger supportBundle.onBlocked target.explicitTableLocks batch.flushOnTableChange",
            .boolean, default: "false")
        add(
            "source.requireTLS target.requireTLS target.preserveSourceGTIDs sourceReconnect.enabled targetReconnect.enabled skipErrors.recordSkippedTransactions batch.overlapPreparation",
            .boolean, default: "true")
        add("target.nativeAutoStartDisabled", .boolean, example: "true", required: true, allowed: ["true"])
        add("source.host", .string, example: "source.example.com", required: true)
        add("source.port", .integer, example: "3306", required: true)
        add("source.username", .string, example: "capture", required: true)
        add("target.username", .string, example: "applier", required: true)
        add("target.host", .string, example: "target.example.com")
        add("target.port", .integer, example: "3306")
        add("target.unixSocket", .string, example: "/var/run/mysqld/mysqld.sock")
        add("source.password target.password", .string, example: "'REPLACE_PASSWORD'")
        add("source.passwordEnvironment", .string, example: "REPLICATOR_SOURCE_PASSWORD")
        add("target.passwordEnvironment", .string, example: "REPLICATOR_TARGET_PASSWORD")
        add("source.caFile target.caFile", .string, example: "/etc/mysql-replicator/ca.pem")
        add("source.serverHostname", .string, example: "source.example.com")
        add("target.serverHostname", .string, example: "target.example.com")
        add(
            "source.tlsVerification target.tlsVerification", .enumeration, default: "verify-identity",
            allowed: ["verify-identity", "verify-ca"])
        add("source.serverID", .integer, example: "9100", required: true)
        add("source.sourceUUID", .string, example: "00000000-0000-0000-0000-000000000001", required: true)
        add("source.mode", .enumeration, example: "gtid", required: true, allowed: ["gtid", "file-position"])
        add(
            "source.start.executedGTIDs", .string, example: "'00000000-0000-0000-0000-000000000001:1-10'",
            required: true)
        add("source.start.file archive.firstFile", .string, example: "binlog.000001")
        add("source.start.position", .integer, example: "4", units: "bytes")
        add("source.stopAfterTransactions", .integer, example: "10000", units: "transactions")
        add("source.stopAfterGTIDs", .string, example: "'00000000-0000-0000-0000-000000000001:1-20000'")
        add("source.lowerCaseTableNames", .integer, default: "0", allowed: ["0", "1"])
        add("archive.lowerCaseTableNames", .integer, example: "0", allowed: ["0", "1"])
        add("source.idleTimeoutSeconds", .integer, default: "15", units: "seconds")
        add("source.maximumEventBytes", .integer, default: "67108864", units: "bytes")
        add(
            "source.maximumTransactionBytes source.downloadCacheBytes maximumRelayBytes storage.maximumSQLiteBytes",
            .integer, default: "268435456", units: "bytes")
        add("target.transport", .enumeration, default: "sql", allowed: ["sql", "binlog"])
        add("ddlPolicy.triggers", .enumeration, default: "skip", allowed: ["skip", "reject"])
        add("ddlPolicy.events", .enumeration, default: "reject", allowed: ["reject"])
        add("ddlTimeoutSeconds", .integer, default: "300", units: "seconds")
        add("replicateWildDoTable replicateWildIgnoreTable", .stringList, default: "[]", example: "['app.%']")
        add("compatibility.collations", .stringMap, default: "{}", example: "{utf8mb4_0900_ai_ci: utf8mb4_unicode_ci}")
        add(
            "skipErrors.codes", .stringList, default: "[]", example: "['ddl.unsupported_alter']",
            allowed: [
                "ddl.unsupported_statement", "ddl.unsupported_column_type", "ddl.unsupported_alter",
                "ddl.unsupported_collation",
                "dml.multiple_statements", "dml.multiple_tables", "mysql.1062",
            ])
        add(
            "sourceReconnect.initialDelaySeconds targetReconnect.initialDelaySeconds", .integer, default: "1",
            units: "seconds")
        add(
            "sourceReconnect.maximumDelaySeconds targetReconnect.maximumDelaySeconds", .integer, default: "30",
            units: "seconds")
        add(
            "sourceReconnect.maximumAttempts targetReconnect.maximumAttempts", .integer, default: "0", units: "attempts"
        )
        add("storage.minimumFreeDiskBytes", .integer, default: "536870912", units: "bytes")
        add("storage.pruneAtPercent", .integer, default: "80", units: "percent")
        add("storage.historyRetentionSeconds", .integer, default: "86400", units: "seconds")
        add(
            "storage.snapshotEveryTransactions storage.capacityCheckEveryTransactions", .integer, default: "1000",
            units: "transactions")
        add("storage.capacityCheckIntervalSeconds", .integer, default: "5", units: "seconds")
        add("batch.maximumInsertRows", .integer, default: "32", units: "rows")
        add("batch.maximumInsertBytes", .integer, default: "1048576", units: "bytes")
        add("batch.maximumTransactions", .integer, default: "8", units: "transactions")
        add("batch.maximumPreparedBatches", .integer, default: "8", units: "batches")
        add("batch.maximumRows", .integer, default: "4096", units: "rows")
        add("batch.maximumWireBytes", .integer, default: "8388608", units: "bytes")
        add("batch.maximumDelayMilliseconds", .integer, default: "25", units: "milliseconds")
        add("archive.directory", .string, example: "./binlogs", required: true)
        add("archive.maximumBytes", .integer, default: "68719476736", units: "bytes")
        add("archive.files", .stringList, example: "['binlog.000001', 'binlog.000002']")
        add("supportBundle.directory", .string, example: "./support-bundles")
        add("supportBundle.output", .string, example: "./support.tar")
        add("supportBundle.format", .enumeration, default: "tar", allowed: ["tar", "directory"])
        add("supportBundle.binlogContextBytes", .integer, default: "4194304", units: "bytes")
        add("supportBundle.maximumBytes", .integer, default: "2147483648", units: "bytes")
        add("supportBundle.logs", .stringList, default: "[]", example: "['/var/log/mysql-replicator.log']")
        add("statistics.sourcePollIntervalSeconds", .integer, default: "15", units: "seconds")
        add("statistics.rateWindowSeconds", .integer, default: "60", units: "seconds")
        return result
    }()

    private static func applicableCommands(_ name: String) -> Set<String> {
        let scope = name.split(separator: ".").first.map(String.init) ?? name
        var result: Set<String> = []
        // Offline recovery validates the saved apply configuration, but never connects.
        if scope != "archive" { result.formUnion(["run", "replay", "recovery", "skip"]) }
        if scope == "sourceReconnect" || name == "statistics.sourcePollIntervalSeconds" {
            result.subtract(["replay", "recovery", "skip"])
        }
        if scope == "source" { result.formUnion(["fetch", "blackhole", "inspect"]) }
        if scope == "profile" { result.insert("fetch") }
        if scope == "archive" {
            result.formUnion(["fetch", "replay", "support-bundle"])
            if name == "archive.files" { result.remove("fetch") }
        }
        if scope == "supportBundle" { result.insert("support-bundle") }
        if name == "stateDirectory" { result.formUnion(["ctl", "support-bundle"]) }
        return result
    }
}
