import Foundation

/// Native replication semantics, separate from optional user translations.
/// Version numbers use MySQL's major * 10000 + minor * 100 + patch encoding.
/// Current profiles identify a release series. Both supported series are wholly
/// on one side of each boundary here. Do not infer an 8.0 patch version this way.
struct NativeReplicationRules {
    enum CheckConstraints: Equatable { case discard, preserve, targetUnsupported }
    static let checkConstraintsIntroduced: UInt32 = 80016
    static let undefinedServerVersion: UInt32 = 999999
    static let ignoredChecksRule = "source-before-8.0.16-ignores-checks"
    let sourceVersion: UInt32
    let targetVersion: UInt32

    init(sourceVersion:UInt32,targetVersion:UInt32) {
        self.sourceVersion=sourceVersion;self.targetVersion=targetVersion
    }
    init(profile:ReplicationProfile) {
        self.init(sourceVersion:profile.sourceContract == .mysql57 ? 50700 : 80400,
                  targetVersion:profile.targetContract.versionPrefix == "5.7." ? 50700 : 80400)
    }
    /// MySQL sql_check_constraint.cc and sql_table.cc clear the specification
    /// list in SQL workers for an unknown or pre-8.0.16 original source version.
    /// Profiles currently provide the source series, not chained-origin metadata.
    var checkConstraints: CheckConstraints {
        if sourceVersion == Self.undefinedServerVersion || sourceVersion < Self.checkConstraintsIntroduced { return .discard }
        return targetVersion < Self.checkConstraintsIntroduced ? .targetUnsupported : .preserve
    }
}
