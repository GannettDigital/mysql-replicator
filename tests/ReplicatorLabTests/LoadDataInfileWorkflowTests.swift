import XCTest

@testable import ReplicatorLabCore

final class LoadDataInfileWorkflowTests: XCTestCase {
    func testSourceSQLAndFinalChecksRetainTheOriginalImport() throws {
        let original = try XCTUnwrap(DMLCompatibilityCases.cases.first { $0.id == "load" })
        let phase = LoadDataInfileWorkflow.phase
        XCTAssertEqual(original.replicatedReplacement, LoadDataInfileWorkflow.test.id)
        XCTAssertEqual(original.phases.count, 1)
        XCTAssertEqual(phase.steps.count, 3)
        XCTAssertEqual(phase.steps.map(\.transactions), [1, 0, 1])
        XCTAssertFalse(phase.steps.contains(where: \.restartBefore))
        XCTAssertEqual(
            phase.steps[0].sql,
            "CREATE TABLE \(LoadDataInfileWorkflow.table)(\(original.definition)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin")
        XCTAssertEqual(
            phase.steps.dropFirst().map(\.sql).joined(separator: "; "),
            original.phases[0].sql.replacingOccurrences(of: "poc.matrix_load", with: LoadDataInfileWorkflow.table))
        XCTAssertEqual(try XCTUnwrap(DDLExecutionPhase.plan(phase.steps)).count, 1)
        let final = LoadDataInfileWorkflow.observations
        try final.validate([phase])
        XCTAssertEqual(final.databases, ["poc"])
        XCTAssertTrue(final.cleanup.isEmpty)
        XCTAssertEqual(final.checks[0].check.sql, original.phases[0].check.replacingOccurrences(
            of: "poc.matrix_load", with: LoadDataInfileWorkflow.table))
        XCTAssertEqual(final.checks[0].check.expected, "1")
        XCTAssertEqual(final.checks[1].check.expected, "1\t10\n2\t20")
        XCTAssertEqual(LoadDataInfileWorkflow.assertions.count, 5)
    }

    func testSourceExportMustNotAdvanceGTIDsOrOffsets() throws {
        let writes = results()
        XCTAssertEqual(try LoadDataInfileWorkflow.validateSource(writes), [1, 0, 1])
        XCTAssertThrowsError(try LoadDataInfileWorkflow.validateSource(Array(writes.dropLast())))
        for index in [0, 2] {
            var bad = writes
            bad[index] = .init(
                write: writes[index].write, start: writes[index].start, end: writes[index].end,
                gtids: "uuid:2-3", warnings: "")
            XCTAssertThrowsError(try LoadDataInfileWorkflow.validateSource(bad))
        }
        for end in [
            Boundary(file: "binlog.000002", position: 200, gtids: "uuid:1-2"),
            Boundary(file: "binlog.000001", position: 201, gtids: "uuid:1-2"),
            Boundary(file: "binlog.000001", position: 200, gtids: "uuid:1-3"),
        ] {
            var bad = writes
            bad[1] = .init(write: writes[1].write, start: writes[1].start, end: end, gtids: "", warnings: "")
            XCTAssertThrowsError(try LoadDataInfileWorkflow.validateSource(bad))
        }
        var bad = writes
        bad[1] = .init(
            write: .init(id: "unexpected", sql: writes[1].write.sql), start: writes[1].start,
            end: writes[1].end, gtids: "", warnings: "")
        XCTAssertThrowsError(try LoadDataInfileWorkflow.validateSource(bad))
    }

    func testProgressRequiresTwoRowsTwoTransactionsAndAnExactCheckpoint() throws {
        let before: [String: Any] = ["transactionsApplied": 10, "ddlApplied": 2, "rowsApplied": 3]
        let end = results().last!.end
        let after: [String: Any] = [
            "transactionsApplied": 12, "ddlApplied": 3, "rowsApplied": 5,
            "appliedGTIDSet": end.gtids, "appliedPosition": ["file": end.file, "position": "300"],
        ]
        try LoadDataInfileWorkflow.validateProgress(before: before, after: after, end: end)
        for (key, value) in [
            ("transactionsApplied", 13), ("ddlApplied", 4), ("rowsApplied", 4),
        ] {
            var bad = after
            bad[key] = value
            XCTAssertThrowsError(try LoadDataInfileWorkflow.validateProgress(before: before, after: bad, end: end))
            bad.removeValue(forKey: key)
            XCTAssertThrowsError(try LoadDataInfileWorkflow.validateProgress(before: before, after: bad, end: end))
        }
        let boundaries: [(String, Any)] = [
            ("appliedGTIDSet", "uuid:1-2"),
            ("appliedPosition", ["file": "binlog.000002", "position": "300"]),
            ("appliedPosition", ["file": end.file, "position": "299"]),
            ("appliedPosition", ["file": end.file]),
        ]
        for (key, value) in boundaries {
            var bad = after
            bad[key] = value
            XCTAssertThrowsError(try LoadDataInfileWorkflow.validateProgress(before: before, after: bad, end: end))
        }
    }

    func testCatalogReplacementKeepsTheTenOriginalSelections() throws {
        let catalog = LabScenario.correctness
        XCTAssertFalse(catalog.contains { $0.id == "matrix-load" || $0.id == "bootstrap-matrix-load" })
        let test = try XCTUnwrap(catalog.first { $0.id == LoadDataInfileWorkflow.test.id })
        XCTAssertEqual(test.family, "dml")
        XCTAssertTrue(test.requiresMainApplier)
        for profile in LabProfile.allCases {
            let variants: [LabVariant] = profile == .forward
                ? [.standard, .positionMinimal, .gtidFull, .lowercaseTables] : [.standard, .lowercaseTables]
            for variant in variants {
                XCTAssertNil(test.reason(profile, variant: variant))
                XCTAssertEqual(test.fields(profile, variant: variant)["assertions"] as? [String], LoadDataInfileWorkflow.assertions)
                XCTAssertEqual(test.fields(profile, variant: variant)["replaces"] as? [String], ["matrix-load"])
            }
        }
        XCTAssertThrowsError(try LabScenario.select(tier: "full", family: nil, ids: ["matrix-load"])) {
            XCTAssertTrue(String(describing: $0).contains("matrix-load was replaced by dml-load-data-infile"))
        }
    }

    private func results() -> [LabSQLPhase.Result] {
        let a = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        let b = Boundary(file: a.file, position: 200, gtids: "uuid:1-2")
        let c = Boundary(file: a.file, position: 300, gtids: "uuid:1-3")
        let writes = LoadDataInfileWorkflow.phase.writes(transactional: false)
        return [
            .init(write: writes[0], start: a, end: b, gtids: "uuid:2", warnings: ""),
            .init(write: writes[1], start: b, end: b, gtids: "", warnings: ""),
            .init(write: writes[2], start: b, end: c, gtids: "uuid:3", warnings: ""),
        ]
    }
}
