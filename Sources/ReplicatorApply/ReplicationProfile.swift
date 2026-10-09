import Foundation
import ReplicatorCapture

/// Each profile is qualified independently; missing configuration retains the
/// original MyISAM contract, never an inferred engine/version combination.
public enum ReplicationProfile: String, Codable {
    case mysql84To57MyISAM = "mysql84-to-mysql57-myisam"
    case mysql57To84InnoDB = "mysql57-to-mysql84-innodb"

    var transactional: Bool { self == .mysql57To84InnoDB }
    var sourceContract: SourceContract { transactional ? .mysql57 : .mysql84 }
}
