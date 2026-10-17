import Foundation

/// Capture settings are independent of topology. Historical combinations remain
/// explicit obligations; they are not inferred from a successful default run.
enum LabVariant: String, CaseIterable {
    case standard = "default"
    case positionMinimal = "position-minimal"
    case gtidFull = "gtid-full"
    case lowercaseTables = "lowercase-tables"
    var lowerCaseTableNames: Int { self == .lowercaseTables ? 1 : 0 }

    var mode: String { self == .positionMinimal ? "file-position" : "gtid" }
    var metadata: String { self == .positionMinimal ? "MINIMAL" : "FULL" }
    var catalogProfile: String? {
        switch self {
        case .standard,.lowercaseTables: return nil
        case .positionMinimal: return "swift.position.metadata-minimal"
        case .gtidFull: return "swift.gtid.metadata-full"
        }
    }
    func reason(_ profile: LabProfile) -> String? {
        (self == .positionMinimal || self == .gtidFull) && !profile.hasOptionalMetadata ? "MySQL 5.7 does not expose binlog_row_metadata; use its default GTID/bootstrap variant." : nil
    }
    func start(_ boundary: Boundary) -> [String:Any] {
        var result: [String:Any] = ["executedGTIDs":boundary.gtids]
        if self != .gtidFull { result["file"]=boundary.file; result["position"]=boundary.position }
        return result
    }
    var fields: [String:Any] { ["id":rawValue,"lower_case_table_names":lowerCaseTableNames,"positioning":mode,"start_coordinates":self != .gtidFull,"forward_row_metadata":metadata] }
}
