import Foundation

/// Uses a new connection. Never call the writer-ownership or scratch-table preflight here.
enum TargetReadiness {
    /// Early replay probes may change only this session. Do not acquire writer
    /// ownership, assign source GTIDs, or create scratch objects before validation.
    static func checkForReplay(_ target: TargetSession) throws {
        try target.preflightSettings()
        try checkEngine(target)
        try target.nativeExclusion()
        try target.preflightSession()
        try checkTimestampDefaults(target)
    }
    private static func checkEngine(_ target: TargetSession) throws {
        let rows = try target.query("SHOW ENGINES").0
        try require(
            rows.contains {
                $0.column("Engine")?.string?.lowercased() == target.contract.engine.lowercased()
                    && ["YES", "DEFAULT"].contains($0.column("Support")?.string ?? "")
            }, "target engine \(target.contract.engine) is not available")
    }
    private static func checkTimestampDefaults(_ target: TargetSession) throws {
        try target.timestampDefaults.prepare(
            read: { try target.scalar("SELECT @@SESSION.explicit_defaults_for_timestamp AS v") },
            enable: { _ = try target.query("SET SESSION explicit_defaults_for_timestamp=1") })
    }
    static func inspect(_ configuration: ApplyConfiguration, _ password: String, _ report: ValidationReport) {
        var target: TargetSession?
        guard
            report.check(
                "target.connection", nextStep: "Check target address, TLS, credentials, and network access.",
                {
                    target = try TargetSession(configuration: configuration, password: password)
                    return "Authenticated target connection opened."
                }), let target
        else { return }
        guard
            report.check(
                "target.settings",
                nextStep:
                    "Match target version, UUID, GTID settings, binlog settings, and table-name case to the profile.",
                {
                    try target.preflightSettings()
                    return "Target identity, version, binlog settings, TLS session, and packet limit passed."
                })
        else { return }
        report.check("target.engine", nextStep: "Enable the target storage engine required by the profile.") {
            try checkEngine(target)
            return "Target engine \(target.contract.engine) is available. Existing table engines are not inspected."
        }
        report.check(
            "target.nativeReplication",
            nextStep: "Remove native replication channels and stop native replication before run/replay."
        ) {
            try target.nativeExclusion()
            return "No native replication channel or active worker found."
        }
        report.check(
            "target.session",
            nextStep: "Check target session privileges. For GTID_NEXT limits, see docs/GTID_PRESERVATION.md."
        ) {
            try target.preflightSession()
            return "Required session changes passed. No transaction or source GTID was issued."
        }
        report.check(
            "target.timestampDefaults",
            nextStep: "Ask the DBA to set explicit_defaults_for_timestamp=ON, then reconnect."
        ) {
            try checkTimestampDefaults(target)
            return "Target session explicit_defaults_for_timestamp is ON."
        }
        report.unchecked(
            "target.writes",
            "No DDL, DML, BINLOG event, table lock, or scratch object was issued. Object-specific privileges, schema compatibility, and future writes are not proved.",
            nextStep: "Check target grants for the tables and DDL in this workload. See docs/INSTALL.md.")
        report.unchecked(
            "target.ownership",
            "Validation does not acquire the target writer lock. Run/replay must acquire it at startup.")
    }
}
