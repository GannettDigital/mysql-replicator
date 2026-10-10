import Foundation
import ReplicatorCapture

/// Each profile is qualified independently; missing configuration retains the
/// original MyISAM contract, never an inferred engine/version combination.
public enum ReplicationProfile: String, Codable, CaseIterable {
    case mysql84To57MyISAM = "mysql84-to-mysql57-myisam"
    case mysql57To84InnoDB = "mysql57-to-mysql84-innodb"
    case mysql57To57MyISAM = "mysql57-to-mysql57-myisam"

    var transactional: Bool { targetContract.transactional }
    public var sourceContract: SourceContract {
        switch self {
        case .mysql84To57MyISAM: return .mysql84
        case .mysql57To84InnoDB, .mysql57To57MyISAM: return .mysql57
        }
    }
}
