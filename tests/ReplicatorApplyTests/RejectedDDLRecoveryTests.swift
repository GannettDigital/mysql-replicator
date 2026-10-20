import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ResumeTests {
    private func rejectedDDLFixture(
        profile: ReplicationProfile = .mysql57To57InnoDB, preserve: Bool = false
    ) throws -> (URL, ApplyConfiguration, CompleteTransaction) {
        let path = try directory()
        let binlog = helper.root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog")
        let history = try JSONDecoder().decode(
            SchemaHistory.self,
            from: Data(
                contentsOf:
                    helper.root.appendingPathComponent("tests/ReplicatorCodecTests/Schema/source-positive.json")))
        var statements: [CompleteTransaction] = []
        try Inspection.inspectTransactions(
            file: binlog, sourceFile: "binlog.000003", history: history, includeRaw: true
        ) {
            if $0.outcome == .statement { statements.append($0) }
        }
        let group = try XCTUnwrap(statements.last)
        let id = try XCTUnwrap(group.gtid)
        let config = try helper.config(
            path.path, profile: profile.rawValue, preserveSourceGTIDs: preserve,
            baselineGTIDs: id.sid.lowercased() + ":1-" + String(UInt64(id.sequence)! - 1))
        let bytes = try Data(contentsOf: binlog)
        let length = (0..<4).reduce(0) { $0 | Int(bytes[4 + 9 + $1]) << (8 * $1) }
        let format = try BinlogDecoder().decode(Data(bytes[4..<4 + length]), at: 4, includeRaw: true)
        let store = try StateStore(configuration: config)
        try store.bindTargetIdentity(target)
        try store.running()
        try store.append(
            .init(
                kind: "formatContext", file: group.start.file,
                observedPosition: String(format.nextPosition), event: format, rawBase64: nil))
        for event in group.events {
            try store.append(
                .init(
                    kind: "event", file: group.start.file,
                    observedPosition: String(event.nextPosition), event: event, rawBase64: nil))
        }
        try store.begin(group)
        guard case .query(let query) = group.events[1].control else { throw ApplyError("missing fixture query") }
        try store.recordTargetFailure(
            .init(
                reason: "DDL preparation denied", statement: .init(), rows: [],
                ddlGTID: id.canonical, ddlSQL: String(decoding: query.sql, as: UTF8.self),
                ddlContext: DDLQueryContextDiagnostic(query: query)))
        try store.block("DDL preparation denied")
        return (path, config, group)
    }

    func testRejectedDDLRetryPreservesCheckpointAndAuditsAllProfiles() throws {
        for profile in [
            ReplicationProfile.mysql84To57MyISAM, .mysql57To57MyISAM, .mysql57To57InnoDB, .mysql57To84InnoDB,
        ] {
            for preserve in [false, true] {
                let (path, config, group) = try rejectedDDLFixture(profile: profile, preserve: preserve)
                let before = try Recovery.inspect(configuration: config)
                XCTAssertEqual(before.pending.count, 1)
                XCTAssertNotNil(before.pending[0].rejectedDDL)
                XCTAssertEqual(before.pending[0].rows.count, 0)
                for action in [Recovery.Action.skip, .markApplied] {
                    XCTAssertThrowsError(
                        try Recovery.resolve(
                            configuration: config, action: action,
                            gtids: group.gtid!.canonical, reason: "wrong action"))
                }
                XCTAssertThrowsError(
                    try Recovery.resolve(
                        configuration: config, action: .retry,
                        gtids: "none", reason: "wrong GTID"))
                let resolved = try Recovery.resolve(
                    configuration: config, action: .retry,
                    gtids: group.gtid!.canonical, reason: "DBA corrected the session default")
                XCTAssertEqual(resolved.lifecycle, "STOPPED")
                XCTAssertEqual(resolved.resumeGTIDSet, before.appliedGTIDSet)
                let reopened = try StateStore(configuration: config, initialize: false)
                XCTAssertEqual(reopened.gtids, before.appliedGTIDSet)
                XCTAssertEqual(reopened.transactions, 0)
                XCTAssertEqual(reopened.ddlApplied, 0)
                XCTAssertNil(reopened.pendingGTID)
                XCTAssertEqual(try reopened.pendingGTIDMarkers(), [])
                XCTAssertEqual(
                    try helper.sqlite(
                        path.appendingPathComponent("state.sqlite"),
                        "SELECT action,json_extract(evidence_json,'$.pending[0].rejectedDDL.sql') FROM recovery_audit"),
                    [["retry", before.pending[0].rejectedDDL!.sql]])
            }
        }
    }

    func testRejectedDDLRetryRejectsMissingUncertainOrMismatchedEvidence() throws {
        for damage in [
            "DELETE FROM target_failure",
            "UPDATE target_failure SET diagnostic_json=json_set(diagnostic_json,'$.statement.phase','possiblyExecuted')",
            "UPDATE target_failure SET diagnostic_json=json_set(diagnostic_json,'$.statement.phase','acknowledged')",
            "UPDATE target_failure SET diagnostic_json=json_set(diagnostic_json,'$.ddlGTID','wrong:1')",
            "UPDATE target_failure SET diagnostic_json=json_set(diagnostic_json,'$.ddlSQL','DROP TABLE wrong')",
            "UPDATE target_failure SET diagnostic_json=json_set(diagnostic_json,'$.ddlContext.sourceSQLBase64','AA==')",
            "UPDATE groups SET end_position=CAST(end_position AS INTEGER)+1 WHERE status='PENDING'",
            "UPDATE state SET lifecycle='RUNNING'",
            "INSERT INTO ddl_intents(gtid,target_sql,status,created_at) SELECT active_gtid,'CREATE TABLE t(id INT)','PENDING','test' FROM state",
            "INSERT INTO ddl_intents(gtid,target_sql,status,created_at) SELECT active_gtid,'CREATE TABLE t(id INT)','DONE','test' FROM state",
        ] {
            let (path, config, group) = try rejectedDDLFixture()
            try write(path, damage)
            XCTAssertThrowsError(
                try Recovery.resolve(
                    configuration: config, action: .retry,
                    gtids: group.gtid!.canonical, reason: "must reject damaged or uncertain evidence"), damage)
            XCTAssertEqual(
                try helper.sqlite(
                    path.appendingPathComponent("state.sqlite"),
                    "SELECT COUNT(*) FROM groups WHERE status='PENDING'"), [["1"]])
        }
    }

    func testRejectedDDLRetryRequiresIntactRelayAndRollsBackAtomically() throws {
        let (path, config, group) = try rejectedDDLFixture()
        try write(path, "CREATE TRIGGER reject_retry BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'injected'); END")
        XCTAssertThrowsError(
            try Recovery.resolve(
                configuration: config, action: .retry,
                gtids: group.gtid!.canonical, reason: "injected failure"))
        XCTAssertEqual(try Recovery.inspect(configuration: config).pending.count, 1)
        XCTAssertEqual(
            try helper.sqlite(
                path.appendingPathComponent("state.sqlite"),
                "SELECT COUNT(*) FROM sqlite_master WHERE name='recovery_audit'"), [["0"]])
        try write(path, "DROP TRIGGER reject_retry")
        let relay = try FileHandle(forUpdating: path.appendingPathComponent("relay.frames"))
        try relay.truncate(atOffset: 10)
        try relay.close()
        XCTAssertThrowsError(
            try Recovery.resolve(
                configuration: config, action: .retry,
                gtids: group.gtid!.canonical, reason: "missing relay"))
    }
}
