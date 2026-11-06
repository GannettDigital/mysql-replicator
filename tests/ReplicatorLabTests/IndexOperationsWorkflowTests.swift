import Foundation
import XCTest

@testable import ReplicatorLabCore

final class IndexOperationsWorkflowTests: XCTestCase {
    func testDistinctTableSetsKeepAllSQLMetadataAndNativeCases() throws {
        let original = ModifyIndexCases.standaloneCases
        let workflows = ModifyIndexCases.indexWorkflowCases
        XCTAssertEqual(workflows.count, 12)
        XCTAssertEqual(workflows.reduce(0) { $0 + $1.workload.count }, 16)
        XCTAssertEqual(workflows.reduce(0) { $0 + $1.workload.reduce(0) { $0 + $1.affectedRows } }, 18)
        XCTAssertEqual(workflows.reduce(0) { $0 + ($1.workload.isEmpty ? 4 : 5) }, 57)
        var allNames: Set<String> = []
        for (old, new) in zip(original, workflows) {
            let map = ModifyIndexCases.indexTableMap(old)
            XCTAssertTrue(allNames.isDisjoint(with: map.values))
            allNames.formUnion(map.values)
            func restored(_ sql: String) -> String {
                map.sorted { $0.value.count > $1.value.count }.reduce(sql) {
                    $0.replacingOccurrences(of: "demo." + $1.value, with: "demo." + $1.key)
                }
            }
            XCTAssertEqual(restored(new.seed), old.seed)
            XCTAssertEqual(restored(new.sql), old.sql)
            XCTAssertEqual(new.workload.map { restored($0.sql) }, old.workload.map(\.sql))
            XCTAssertEqual(new.workload.map(\.rows), old.workload.map(\.rows))
            XCTAssertEqual(new.workload.map(\.affectedRows), old.workload.map(\.affectedRows))
            XCTAssertEqual(new.columns, old.columns)
            XCTAssertEqual(new.indexes, old.indexes)
            XCTAssertEqual(new.retained, old.retained)
            XCTAssertEqual(new.test.id, old.test.id)
            XCTAssertEqual(new.test.file, old.test.file)
            XCTAssertEqual(new.test.line, old.test.line)
            XCTAssertTrue(DDLCoverageCases.registry.contains { $0.test.id == old.native.id })
            let scenario = try XCTUnwrap(LabScenario.correctness.first { $0.id == new.test.id })
            for profile in LabProfile.allCases { XCTAssertNil(scenario.reason(profile, variant: .standard)) }
        }
    }

    func testSetupReplicatesSingleTableDropsAndSourceSeedsWithoutSessionSuppression() {
        let tests = ModifyIndexCases.indexWorkflowCases
        let setup = ModifyIndexCases.indexSetup(tests)
        XCTAssertFalse(setup.contains("sql_log_bin"))
        XCTAssertFalse(setup.contains("DROP TABLE IF EXISTS demo.mi"))
        let statements = setup.components(separatedBy: "; ")
        let drops = statements.filter { $0.hasPrefix("DROP TABLE") }
        XCTAssertEqual(drops.count, 37)
        XCTAssertTrue(drops.allSatisfy { !$0.contains(",") })
        for test in tests {
            for name in ModifyIndexCases.indexTableMap(test).values {
                XCTAssertTrue(drops.contains("DROP TABLE IF EXISTS demo." + name))
            }
        }
        XCTAssertEqual(statements.filter { $0.hasPrefix("CREATE TABLE") }.count, 12)
        XCTAssertEqual(statements.filter { $0.hasPrefix("INSERT INTO") }.count, 12)
    }

    func testLikeAndRenameSelectBothTableNamesWithoutAcceptingExtraRowsOrDDL() throws {
        for id in ["ddl-index-like", "ddl-index-table-rename"] {
            let test = try XCTUnwrap(ModifyIndexCases.indexWorkflowCases.first { $0.test.id == id })
            let tables = Set(ModifyIndexCases.indexTableMap(test).values)
            let source = ModifyIndexCases.indexTableMap(test)["mi"]!
            func row(_ table: String) -> String {
                "### INSERT INTO `demo`.`\(table)`\n### SET\n###   @1=2 /* INT */"
            }
            let decoded = row("unrelated") + "\n" + test.sql + "\n" + row(test.table) + "\n" + row("unrelated")
            let lines = try ModifyIndexCases.columnBinlog(decoded, test: test, tables: tables)
            XCTAssertEqual(lines, [test.sql, "### INSERT INTO `demo`.`\(test.table)`", "### SET", "###   @1=2"])
            for broken in [
                decoded + "\n" + row(source), decoded + "\n" + test.sql,
                decoded.replacingOccurrences(of: test.sql, with: "unrelated DDL"),
                test.sql + "\n" + row("unrelated"),
            ] {
                XCTAssertThrowsError(try ModifyIndexCases.columnBinlog(broken, test: test, tables: tables))
            }
        }
    }

    func testPublishedHistoryChecksRenameTransitionsAndExactTransactionInterval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner(root: directory)
        let file = directory.appendingPathComponent("history.sqlite")
        func query(_ sql: String) throws -> String { try runner.run(["sqlite3", file.path, sql]).text }
        let test = try XCTUnwrap(ModifyIndexCases.indexWorkflowCases.first { $0.test.id == "ddl-index-table-rename" })
        let schema =
            "{\"database\":\"demo\",\"table\":\"\(test.table)\",\"columns\":[{},{},{},{}],\"secondaryIndexes\":[]}"
        let sql = test.sql.replacingOccurrences(of: "'", with: "''")
        _ = try query(
            """
            PRAGMA user_version=14;
            CREATE TABLE ddl_intents(gtid TEXT,status TEXT,target_sql TEXT,after_schema_id INTEGER);
            CREATE TABLE schemas(id INTEGER,current INTEGER,schema_json TEXT);
            CREATE TABLE ddl_details(gtid TEXT,transitions_json TEXT);
            CREATE TABLE row_intents(gtid TEXT,status TEXT,schema_id INTEGER);
            INSERT INTO ddl_intents VALUES('uuid:10','DONE','\(sql)',NULL),('uuid:20','DONE','other DDL',2);
            INSERT INTO schemas VALUES(1,1,'\(schema)'),(2,1,'{"database":"demo","table":"other"}');
            INSERT INTO ddl_details VALUES('uuid:10','[{"after":\(schema)}]');
            INSERT INTO row_intents VALUES('uuid:11','DONE',1),('uuid:21','DONE',2);
            """)
        let result = try ModifyIndexCases.workflowHistory(
            test, gtids: ["uuid:10", "uuid:11"], published: true, query: query)
        XCTAssertEqual(result["schema_id"] as? Int, 1)
        XCTAssertThrowsError(
            try ModifyIndexCases.workflowHistory(test, gtids: ["uuid:20", "uuid:21"], published: true, query: query))
        for mutation in [
            "UPDATE schemas SET current=0 WHERE id=1",
            "INSERT INTO schemas SELECT 3,1,schema_json FROM schemas WHERE id=1",
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
                try ModifyIndexCases.workflowHistory(
                    test, gtids: ["uuid:10", "uuid:11"], published: true, query: query), mutation)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
    }
}
