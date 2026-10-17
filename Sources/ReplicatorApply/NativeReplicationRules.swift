import Foundation

/// Native replication semantics, separate from optional user translations.
/// Version numbers use MySQL's major * 10000 + minor * 100 + patch encoding.
/// Current profiles identify a release series. Both supported series are wholly
/// on one side of each boundary here. Do not infer an 8.0 patch version this way.
struct NativeReplicationRules {
    enum ForeignKeyParentKeys: Equatable { case completeUnique, innodb }
    /// InnoDB permits full leading columns of nonunique or composite indexes.
    /// MySQL 8.4 replica SQL and worker threads turn off the new client default.
    var foreignKeyParentKeys: ForeignKeyParentKeys {
        [507, 804].contains(targetVersion / 100) ? .innodb : .completeUnique
    }
    var foreignKeySessionSQL: String? {
        targetVersion / 100 == 804 ? "SET SESSION restrict_fk_on_non_standard_key=OFF" : nil
    }
    /// 5.7 tests original generated dependencies even when this ALTER removes them.
    var dropChecksOriginalGeneratedDependencies: Bool { targetVersion / 100 == 507 }
    enum CheckConstraints: Equatable { case discard, preserve, targetUnsupported }
    static let checkConstraintsIntroduced: UInt32 = 80016
    static let undefinedServerVersion: UInt32 = 999999
    static let ignoredChecksRule = "source-before-8.0.16-ignores-checks"
    static let conditionalRoutineRule = "mysql57-routine-create-if-not-exists"
    /// Current target profiles are 5.7 and 8.4. Do not infer support for an
    /// unqualified 8.0 patch version from this rule.
    var translateRoutineIfNotExists: Bool { targetVersion / 100 == 507 }
    static let ignoredForeignKeyMatchRule = "mysql57-match-ignores-foreign-key-actions"
    var foreignKeyMatchIgnoresActions: Bool { sourceVersion / 100 == 507 }
    /// InnoDB enforces both actions immediately. The metadata spelling differs.
    var foreignKeyDefaultAction: String { targetVersion / 100 == 507 ? "RESTRICT" : "NO ACTION" }
    /// 8.4.8 can fail this combined ALTER or retain metadata while losing
    /// FK cascades with an explicit INPLACE algorithm. Do not rewrite it.
    var unsafeFKRenameWithAddedColumn: Bool { targetVersion / 100 == 804 }
    /// 5.7 information_schema can read BTREE direction from an unopened .frm.
    /// All 5.7 BTREE parts are ascending, including accepted DESC syntax.
    func indexDirection(_ raw: String?, type: String) -> String? {
        if raw == nil && type == "BTREE" && targetVersion / 100 == 507 { return "A" }
        return raw
    }
    let sourceVersion: UInt32
    let targetVersion: UInt32

    init(sourceVersion: UInt32, targetVersion: UInt32) {
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
    }
    init(profile: ReplicationProfile) {
        self.init(
            sourceVersion: profile.sourceContract == .mysql57 ? 50700 : 80400,
            targetVersion: profile.targetContract.versionPrefix == "5.7." ? 50700 : 80400)
    }
    /// MySQL sql_check_constraint.cc and sql_table.cc clear the specification
    /// list in SQL workers for an unknown or pre-8.0.16 original source version.
    /// Profiles currently provide the source series, not chained-origin metadata.
    var checkConstraints: CheckConstraints {
        if sourceVersion == Self.undefinedServerVersion || sourceVersion < Self.checkConstraintsIntroduced {
            return .discard
        }
        return targetVersion < Self.checkConstraintsIntroduced ? .targetUnsupported : .preserve
    }
}
