import Foundation

/// Lab topology is independent of production implementation classes. Raw IDs
/// match the runtime configuration; the generated YAML pins the selected runtime profile.
public enum LabProfile: String, CaseIterable, Codable {
    case forward = "mysql84-to-mysql57-myisam"
    case reverse = "mysql57-to-mysql84-innodb"

    enum Role: String, CaseIterable { case source, native, target }
    var targetEngine: String { self == .reverse ? "InnoDB" : "MyISAM" }
    func service(_ role: Role) -> String {
        switch role {
        case .source: return self == .reverse ? "target57" : "source"
        case .target: return self == .reverse ? "source" : "target57"
        case .native: return "native"
        }
    }
    func version(_ role: Role) -> String {
        switch role {
        case .source, .native: return self == .reverse ? "5.7" : "8.4"
        case .target: return self == .reverse ? "8.4" : "5.7"
        }
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
