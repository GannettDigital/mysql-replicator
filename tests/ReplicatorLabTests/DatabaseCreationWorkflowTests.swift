import XCTest

@testable import ReplicatorLabCore

final class DatabaseCreationWorkflowTests: XCTestCase {
    func testPhasesKeepSourceVersionSettingsAndIntermediateRows() throws {
        for test in DatabaseCreationCases.cases {
            for source57 in [false, true] {
                let phases = DatabaseCreationWorkflow.phases(test, source57: source57)
                XCTAssertEqual(phases.map(\.id), ["insert", "update", "delete"])
                XCTAssertEqual(
                    phases.map(\.rows), ["1\t73656564\n2\t<NULL>", "1\t73656564\n3\tF09F9880", "1\t73656564"])
                let writes = phases.flatMap(\.writes)
                XCTAssertEqual(writes.count, test.existing ? 4 : 5)
                XCTAssertTrue(writes[0].sql.hasSuffix((source57 ? test.prefix57 : test.prefix) + test.sql))
                XCTAssertTrue(
                    writes.allSatisfy { $0.sql.hasPrefix("SET SESSION collation_server=@@GLOBAL.collation_server; ") })
                XCTAssertFalse(writes.contains { $0.sql.contains("START TRANSACTION") })
                if source57 { XCTAssertFalse(writes.contains { $0.sql.contains("default_collation_for_utf8mb4") }) }
                XCTAssertEqual(writes.filter { $0.id == "create-table" }.count, test.existing ? 0 : 1)
            }
        }
    }

    func testWarningsAndSchemaChecksRejectLostDefaults() throws {
        for test in DatabaseCreationCases.cases {
            let valid = test.existing ? "Note\t1007\tCan't create database; database exists" : ""
            XCTAssertNoThrow(try DatabaseCreationWorkflow.checkWarning(test, valid))
            XCTAssertThrowsError(try DatabaseCreationWorkflow.checkWarning(test, "Warning\t1234\twrong"))
            XCTAssertThrowsError(
                try DatabaseCreationWorkflow.checkWarning(test, test.existing ? "" : "Note\t1007\texists"))
            var schema = [
                "database": test.expected, "columns": "id\tint\tNO\tPRI\t\nnote\tvarchar\tYES\t\t" + test.collation,
                "engine": "MyISAM",
            ]
            XCTAssertNoThrow(try DatabaseCreationWorkflow.checkSchema(test, values: schema, engine: "MyISAM"))
            XCTAssertThrowsError(try DatabaseCreationWorkflow.checkSchema(test, values: schema, engine: "InnoDB"))
            schema["database"] = "latin1\tlatin1_bin"
            XCTAssertThrowsError(try DatabaseCreationWorkflow.checkSchema(test, values: schema, engine: "MyISAM"))
        }
    }

    func testSharedSnapshotChecksEveryOperationAndDatabaseIntent() throws {
        for test in DatabaseCreationCases.cases {
            let writes = DatabaseCreationWorkflow.phases(test, source57: false).flatMap(\.writes).enumerated().map {
                index, write in
                LabSQLPhase.Result(
                    write: write,
                    start: Boundary(file: "binlog.000001", position: UInt64(100 + index * 100), gtids: "uuid:1"),
                    end: Boundary(
                        file: "binlog.000001", position: UInt64(200 + index * 100), gtids: "uuid:1-\(index + 2)"),
                    gtids: "uuid:\(index + 2)", warnings: "")
            }
            func valid(_ sql: String) -> String {
                if sql.contains("ddl_intents") { return "1" }
                guard let write = writes.first(where: { sql.contains("'\($0.gtids)'") }) else {
                    XCTFail("Unexpected SQLite lookup: " + sql)
                    return ""
                }
                return "APPLIED|binlog.000001|\(write.end.position)"
            }
            XCTAssertNoThrow(try DatabaseCreationWorkflow.checkJournal(test, writes: writes, query: valid))
            XCTAssertThrowsError(
                try DatabaseCreationWorkflow.checkJournal(test, writes: Array(writes.dropLast()), query: valid))
            XCTAssertThrowsError(
                try DatabaseCreationWorkflow.checkJournal(test, writes: writes) { sql in
                    sql.contains("ddl_intents") ? "0" : valid(sql)
                })
            for bad in ["PENDING|binlog.000001|200", "APPLIED|binlog.000002|200", "APPLIED|binlog.000001|999", ""] {
                XCTAssertThrowsError(
                    try DatabaseCreationWorkflow.checkJournal(test, writes: writes) { sql in
                        sql.contains("ddl_intents") ? "1" : bad
                    })
            }
        }
    }
}
