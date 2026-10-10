import Foundation

/// Lab topology is independent of production implementation classes. Raw IDs
/// match the runtime configuration; the generated YAML pins the selected runtime profile.
public enum LabProfile: String, CaseIterable, Codable {
    case forward = "mysql84-to-mysql57-myisam"
    case reverse = "mysql57-to-mysql84-innodb"

    case mysql57MyISAM = "mysql57-to-mysql57-myisam"

    case mysql57InnoDB = "mysql57-to-mysql57-innodb"

    enum Role: String, CaseIterable { case source, native, target }

    var transactionalTarget: Bool { targetEngine == "InnoDB" }
    var targetEngine: String { (self == .reverse || self == .mysql57InnoDB) ? "InnoDB" : "MyISAM" }
    var sourceVersion: LabMySQLVersion {
        switch self {
        case .forward: return .mysql84
        case .reverse, .mysql57MyISAM, .mysql57InnoDB: return .mysql57
        }
    }
    var targetVersion: LabMySQLVersion { self == .reverse ? .mysql84 : .mysql57 }
    var nativeVersion: LabMySQLVersion { sourceVersion }
    var hasOptionalMetadata: Bool { sourceVersion == .mysql84 }
    var supportsPositionCapture: Bool { sourceVersion == .mysql84 }
    var composeOverlay: String {
        switch self {
        case .forward: return "docker/dml/compose.yaml"
        case .reverse: return "docker/reverse/compose.yaml"
        case .mysql57MyISAM: return "docker/mysql57-myisam/compose.yaml"
        case .mysql57InnoDB: return "docker/mysql57-innodb/compose.yaml"
        }
    }
    var evidenceVariable: String {
        switch self {
        case .forward: return "REPLICATOR_DML_EVIDENCE_VOLUME"
        case .reverse: return "REPLICATOR_REVERSE_EVIDENCE_VOLUME"
        case .mysql57MyISAM: return "REPLICATOR_MYSQL57_EVIDENCE_VOLUME"
        case .mysql57InnoDB: return "REPLICATOR_MYSQL57_INNODB_EVIDENCE_VOLUME"
        }
    }
    func service(_ role: Role) -> String {
        switch role {
        case .source: return self == .reverse ? "target57" : "source"
        case .target: return self == .reverse ? "source" : "target57"
        case .native: return "native"
        }
    }
    func version(_ role: Role) -> String {
        (role == .target ? targetVersion : sourceVersion).rawValue
    }
    func engine(_ role: Role) -> String { role == .source ? "InnoDB" : targetEngine }
    var session: String { session(.source) }
    func session(_ role: Role) -> String {
        "SET NAMES utf8mb4 COLLATE utf8mb4_bin; SET SESSION time_zone='+00:00'; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION" + (version(role) == "5.7" ? ",NO_AUTO_CREATE_USER'; " : "'; SET SESSION default_collation_for_utf8mb4=utf8mb4_general_ci; ")
    }
    var topology: [[String:String]] {
        Role.allCases.map { ["role":$0.rawValue,"version":version($0),"engine":engine($0),"service":service($0)] }
    }
}

extension LabProfile {
    static func takeProfile(_ args: inout [String]) throws -> LabProfile {
        guard let index=args.firstIndex(of:"--profile"), index+1 < args.count,
              let profile=LabProfile(rawValue:args[index+1]) else { throw LabError("select one explicit --profile: "+LabProfile.allCases.map(\.rawValue).joined(separator:" | ")) }
        args.removeSubrange(index...index+1)
        try require(!args.contains("--profile"),"duplicate --profile")
        return profile
    }
}
