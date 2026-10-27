import Foundation
import XCTest

@testable import ReplicatorLabCore

final class ModifyColumnsTests: XCTestCase {
    func testCatalogRetiresOnlyColumnCasesAndKeepsNativeDefinitions() throws {
        let parent = try XCTUnwrap(LabScenario.correctness.first { $0.id == "ddl-modify-columns" })
        XCTAssertEqual(ModifyIndexCases.columnCases.count, 10)
        XCTAssertEqual(Set(ModifyIndexCases.columnAssertions).count, 56)
        XCTAssertTrue(LabScenario.correctness.contains { $0.id == "ddl-modify-indexed" })
        XCTAssertEqual(ModifyIndexCases.columnCases.reduce(0) { $0 + $1.workload.count }, 16)
        for test in ModifyIndexCases.columnCases {
            XCTAssertFalse(LabScenario.correctness.contains { $0.id == test.test.id })
            XCTAssertTrue(DDLCoverageCases.registry.contains { $0.test.id == test.native.id })
            XCTAssertThrowsError(try LabScenario.select(tier: "full", family: nil, ids: [test.test.id])) {
                XCTAssertTrue(String(describing: $0).contains("was replaced by ddl-modify-columns"))
            }
        }
        for profile in LabProfile.allCases {
            for variant in LabVariant.allCases where variant.reason(profile) == nil && variant != .withoutSourceGTIDs {
                XCTAssertNil(parent.reason(profile, variant: variant))
                XCTAssertEqual(
                    parent.fields(profile, variant: variant)["replaces"] as? [String], ModifyIndexCases.columnIDs)
                XCTAssertEqual(
                    parent.fields(profile, variant: variant)["assertions"] as? [String],
                    ModifyIndexCases.columnAssertions)
            }
        }
        XCTAssertEqual(
            try LabScenario.select(tier: "full", family: nil, ids: [parent.id]).map(\.id), [parent.id])
    }

    func testAggregateEvidenceRejectsMissingOrExtraSubcases() throws {
        var evidence: [String: Any] = Dictionary(
            uniqueKeysWithValues: ModifyIndexCases.columnIDs.map { ($0, ["checked": true]) })
        XCTAssertNoThrow(try ModifyIndexCases.columnEvidence(evidence))
        evidence.removeValue(forKey: "ddl-modify-first")
        XCTAssertThrowsError(try ModifyIndexCases.columnEvidence(evidence))
        evidence["ddl-modify-indexed"] = ["checked": true]
        XCTAssertThrowsError(try ModifyIndexCases.columnEvidence(evidence))
    }

    func testHistoryUsesRetiredSchemaAndExactGTIDIntervalAndRejectsIncompleteRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner(root: directory)
        let file = directory.appendingPathComponent("history.sqlite")
        func query(_ sql: String) throws -> String { try runner.run(["sqlite3", file.path, sql]).text }
        let test = try XCTUnwrap(ModifyIndexCases.columnCases.first { $0.test.id == "ddl-modify-narrow-text" })
        let schema = #"{"database":"demo","table":"mi","columns":[{},{},{},{}],"secondaryIndexes":[]}"#
        let sql = test.sql.replacingOccurrences(of: "'", with: "''")
        _ = try query(
            """
            PRAGMA user_version=14;
            CREATE TABLE ddl_intents(gtid TEXT, status TEXT, target_sql TEXT, after_schema_id INTEGER);
            CREATE TABLE schemas(id INTEGER, current INTEGER, schema_json TEXT);
            CREATE TABLE ddl_details(gtid TEXT, transitions_json TEXT);
            CREATE TABLE row_intents(gtid TEXT, status TEXT, schema_id INTEGER);
            INSERT INTO ddl_intents VALUES('uuid:10','DONE','\(sql)',1),('uuid:20','DONE','later DDL',2);
            INSERT INTO schemas VALUES(1,0,'\(schema)'),(2,1,'{"later":true}');
            INSERT INTO ddl_details VALUES('uuid:10','[{"after":\(schema)}]');
            INSERT INTO row_intents VALUES('uuid:11','DONE',1),('uuid:21','DONE',2);
            """)
        let result = try ModifyIndexCases.columnHistory(test, gtids: ["uuid:10", "uuid:11"], query: query)
        XCTAssertEqual(result["schema_id"] as? Int, 1)
        // Later DDL and rows for the same table must not make an earlier case pass.
        XCTAssertThrowsError(try ModifyIndexCases.columnHistory(test, gtids: ["uuid:20", "uuid:21"], query: query))
        for mutation in [
            "UPDATE row_intents SET schema_id=2 WHERE gtid='uuid:11'",
            "UPDATE row_intents SET status='PENDING' WHERE gtid='uuid:11'",
            "DELETE FROM row_intents WHERE gtid='uuid:11'",
            "INSERT INTO row_intents VALUES('uuid:11','DONE',1)",
            "UPDATE ddl_intents SET status='PENDING' WHERE gtid='uuid:10'",
            "UPDATE ddl_details SET transitions_json='[{\"after\":{}}]' WHERE gtid='uuid:10'",
        ] {
            let backup = directory.appendingPathComponent("before.sqlite")
            try FileManager.default.copyItem(at: file, to: backup)
            _ = try query(mutation)
            XCTAssertThrowsError(
                try ModifyIndexCases.columnHistory(test, gtids: ["uuid:10", "uuid:11"], query: query), mutation)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
    }
}
