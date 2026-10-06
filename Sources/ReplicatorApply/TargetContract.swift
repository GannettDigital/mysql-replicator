import MySQLNIO

/// Version/engine rules, independent of orchestration and SQLite. Add a new
/// qualified contract here rather than broadening existing target guards.
protocol TargetContract {
    var versionPrefix: String { get }
    var engine: String { get }
    var statusSQL: String { get }
    var gtidMode: String { get }
    var gtidConsistency: String { get }
    var supportsDDL: Bool { get }
    func configure(_ target: TargetSession) throws
    func validateTable(_ table: ApplyTable, target: TargetSession) throws
}

struct MySQL57MyISAMContract: TargetContract {
    let versionPrefix = "5.7.", engine = "MyISAM", statusSQL = "SHOW SLAVE STATUS"
    let gtidMode = "OFF_PERMISSIVE", gtidConsistency = "WARN"
    let supportsDDL = true
    func configure(_ target: TargetSession) throws {
        _ = try target.query("SET @@SESSION.GTID_NEXT = 'AUTOMATIC'")
    }
    func validateTable(_ table: ApplyTable, target: TargetSession) throws {}
}

struct MySQL84InnoDBContract: TargetContract {
    let versionPrefix = "8.4.", engine = "InnoDB", statusSQL = "SHOW REPLICA STATUS"
    let gtidMode = "ON", gtidConsistency = "ON"
    let supportsDDL = false
    func configure(_ target: TargetSession) throws {
        // Avoid a privileged GTID_NEXT assignment on managed targets. These
        // writes generate target-local GTIDs; upstream progress lives in SQLite.
        try require(try target.scalar("SELECT @@SESSION.GTID_NEXT AS v") == "AUTOMATIC","target session requires automatic local GTIDs")
        _ = try target.query("SET SESSION foreign_key_checks=1,unique_checks=1")
    }
    func validateTable(_ table: ApplyTable, target: TargetSession) throws {
        let binds: [MySQLData] = [.init(string:table.database),.init(string:table.table)]
        // Qualify FK/cascade semantics separately before permitting them.
        try require(try target.scalar("SELECT COUNT(*) AS v FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_NAME IS NOT NULL AND ((TABLE_SCHEMA=? AND TABLE_NAME=?) OR (REFERENCED_TABLE_SCHEMA=? AND REFERENCED_TABLE_NAME=?))",binds+binds) == "0","InnoDB reverse profile does not yet support foreign keys or cascades")
    }
}

extension ReplicationProfile {
    var targetContract: TargetContract {
        switch self {
        case .mysql84To57MyISAM: return MySQL57MyISAMContract()
        case .mysql57To84InnoDB: return MySQL84InnoDBContract()
        }
    }
}
