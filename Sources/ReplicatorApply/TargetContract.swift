import MySQLNIO
import ReplicatorCodec

/// Version/engine rules, independent of orchestration and SQLite. Add a new
/// qualified contract here rather than broadening existing target guards.
protocol TargetContract {
    var versionPrefix: String { get }
    var engine: String { get }
    var transactional: Bool { get }
    var statusSQL: String { get }
    var gtidMode: String { get }
    var gtidConsistency: String { get }
    func configureDDL(_ target: TargetSession, context: QuerySessionContext) throws
    func ddlSQLMode(_ mode: UInt64) -> UInt64
    func defaultUTF8MB4Collation(_ target: TargetSession) throws -> String?
    func columnDefault(_ value: String?, type: String) throws -> String?
    func columnExtra(_ value: String?, defaultValue: String?, type: String) -> String?
    func configure(_ target: TargetSession) throws
    func validateTable(_ table: ApplyTable, target: TargetSession) throws
}

struct MySQL57MyISAMContract: TargetContract {
    let transactional = false
    let versionPrefix = "5.7.", engine = "MyISAM", statusSQL = "SHOW SLAVE STATUS"
    let gtidMode = "OFF_PERMISSIVE", gtidConsistency = "WARN"
    func configureDDL(_ target: TargetSession, context: QuerySessionContext) throws {}
    func ddlSQLMode(_ mode: UInt64) -> UInt64 { mode }
    func defaultUTF8MB4Collation(_ target: TargetSession) throws -> String? {
        try target.scalar("SELECT DEFAULT_COLLATE_NAME AS v FROM information_schema.CHARACTER_SETS WHERE CHARACTER_SET_NAME='utf8mb4'")
    }
    func columnDefault(_ value: String?, type: String) throws -> String? { value }
    func columnExtra(_ value: String?, defaultValue: String?, type: String) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    func configure(_ target: TargetSession) throws {
        _ = try target.query("SET @@SESSION.GTID_NEXT = 'AUTOMATIC'")
    }
    func validateTable(_ table: ApplyTable, target: TargetSession) throws {}
}

struct MySQL84InnoDBContract: TargetContract {
    let transactional = true
    let versionPrefix = "8.4.", engine = "InnoDB", statusSQL = "SHOW REPLICA STATUS"
    let gtidMode = "ON", gtidConsistency = "ON"
    func ddlSQLMode(_ mode: UInt64) -> UInt64 {
        // MySQL 8.4 system_variables.h MODE_IGNORED_MASK and
        // Query_log_event::do_apply_event discard these obsolete 5.7 bits.
        mode & ~UInt64(0x1003ff00)
    }
    func defaultUTF8MB4Collation(_ target: TargetSession) throws -> String? {
        try target.scalar("SELECT @@SESSION.default_collation_for_utf8mb4 AS v")
    }
    func columnDefault(_ value: String?, type: String) throws -> String? {
        try TargetColumnMetadata.defaultValue(value,type:type,mysql84:true)
    }
    func columnExtra(_ value: String?, defaultValue: String?, type: String) -> String? {
        TargetColumnMetadata.extra(value,defaultValue:defaultValue,type:type)
    }
    func configureDDL(_ target: TargetSession, context: QuerySessionContext) throws {
        // Native 8.4 uses general_ci for 5.7 events without Q_DEFAULT_COLLATION.
        // This preserves source semantics; it does not translate collations.
        try require(context.defaultUTF8MB4Collation == 45,"unexpected 5.7 default utf8mb4 collation")
        _ = try target.query("SET SESSION default_collation_for_utf8mb4=utf8mb4_general_ci")
    }
    func configure(_ target: TargetSession) throws {
        // Avoid a privileged GTID_NEXT assignment on managed targets. These
        // writes generate target-local GTIDs; upstream progress lives in SQLite.
        try require(try target.scalar("SELECT @@SESSION.GTID_NEXT AS v") == "AUTOMATIC","target session requires automatic local GTIDs")
        _ = try target.query("SET SESSION foreign_key_checks=1,unique_checks=1")
    }
    func validateTable(_ table: ApplyTable, target: TargetSession) throws {
        try target.validateForeignKeys(table)
    }
}

extension ReplicationProfile {
    var targetContract: TargetContract {
        switch self {
        case .mysql84To57MyISAM, .mysql57To57MyISAM: return MySQL57MyISAMContract()
        case .mysql57To84InnoDB: return MySQL84InnoDBContract()
        }
    }
}
