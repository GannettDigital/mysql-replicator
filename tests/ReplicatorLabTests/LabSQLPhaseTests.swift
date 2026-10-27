import XCTest

@testable import ReplicatorLabCore

final class LabSQLPhaseTests: XCTestCase {
    func testWritesRetainSessionSettingsWarningsAndTransactionBoundaries() throws {
        let writes: [LabSQLPhase.Write] = [
            .init(id: "alter", sql: "ALTER TABLE t ADD n INT", checkWarnings: true),
            .init(id: "update", sql: "UPDATE t SET n=1"),
        ]
        let queries = try LabSQLPhase.queries(writes, session: "SET NAMES utf8mb4;", status: "SHOW MASTER STATUS")
        XCTAssertEqual(queries.count, 8)
        XCTAssertEqual(Set(queries.map(\.name)).count, 8)
        for query in queries.filter({ $0.name.hasSuffix("/warnings") }) {
            XCTAssertTrue(query.sql.hasPrefix("SET NAMES utf8mb4;"))
            XCTAssertTrue(query.sql.hasSuffix("; SHOW WARNINGS"))
            XCTAssertFalse(query.sql.contains("BEGIN"))
            XCTAssertFalse(query.sql.contains("COMMIT"))
        }
        let start = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        var values = [
            "alter/warnings": "", "alter/delta": "uuid:2", "alter/position": "binlog.000001\t200\t\t",
            "alter/gtids": "uuid:1-2",
            "update/warnings": "", "update/delta": "uuid:3", "update/position": "binlog.000001\t300\t\t",
            "update/gtids": "uuid:1-3",
        ]
        let results = try LabSQLPhase.decode(writes, start: start, values: values)
        XCTAssertEqual(results.map(\.start.position), [100, 200])
        XCTAssertEqual(results.map(\.end.position), [200, 300])
        XCTAssertEqual(results.map(\.gtids), ["uuid:2", "uuid:3"])
        values["alter/warnings"] = "Warning\t1265\ttruncated"
        XCTAssertThrowsError(try LabSQLPhase.decode(writes, start: start, values: values))
        values.removeValue(forKey: "alter/warnings")
        XCTAssertThrowsError(try LabSQLPhase.decode(writes, start: start, values: values))
        XCTAssertThrowsError(try LabSQLPhase.queries(writes + writes, session: "", status: "SHOW MASTER STATUS"))
    }

    func testIndependentTablesKeepOriginalAlterConditionsAndAllIntermediateRows() {
        let original = ModifyIndexCases.columnCases
        let renamed = ModifyIndexCases.columnWorkflowCases
        XCTAssertEqual(Set(renamed.map(\.table)).count, original.count)
        for (old, new) in zip(original, renamed) {
            XCTAssertEqual(new.test.id, old.test.id)
            XCTAssertEqual(new.columns, old.columns)
            XCTAssertEqual(new.indexes, old.indexes)
            XCTAssertEqual(new.retained, old.retained)
            XCTAssertEqual(new.workload.map(\.rows), old.workload.map(\.rows))
            XCTAssertEqual(new.sql.replacingOccurrences(of: new.table, with: old.table), old.sql)
            XCTAssertEqual(
                new.workload.map { $0.sql.replacingOccurrences(of: new.table, with: old.table) },
                old.workload.map(\.sql))
        }
    }

    func testPerStatementJournalChecksRejectWrongOffsetsPendingGroupsAndMissingTransactions() throws {
        let test = ModifyIndexCases.columnWorkflowCases[1]
        let start = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        let writes = [2, 3].map { number in
            LabSQLPhase.Result(
                write: .init(id: test.test.id, sql: "test"), start: start,
                end: Boundary(file: "binlog.000001", position: UInt64(number * 100), gtids: "uuid:1-\(number)"),
                gtids: "uuid:\(number)", warnings: "")
        }
        func correct(_ sql: String) -> String {
            sql.contains("uuid:2") ? "APPLIED|binlog.000001|200" : "APPLIED|binlog.000001|300"
        }
        XCTAssertNoThrow(try ModifyIndexCases.columnBoundaries(test, writes: writes, query: correct))
        XCTAssertThrowsError(
            try ModifyIndexCases.columnBoundaries(test, writes: writes) { _ in "APPLIED|binlog.000001|999" })
        XCTAssertThrowsError(
            try ModifyIndexCases.columnBoundaries(test, writes: writes) { _ in "PENDING|binlog.000001|200" })
        XCTAssertThrowsError(
            try ModifyIndexCases.columnBoundaries(test, writes: Array(writes.prefix(1)), query: correct))
        XCTAssertThrowsError(
            try ModifyIndexCases.columnBoundaries(test, writes: [writes[0], writes[0]], query: correct))
    }

    func testBinlogChecksKeepOnlyTheNamedTableAndRejectMissingOrExtraRows() throws {
        let test = ModifyIndexCases.columnWorkflowCases[1]  // One following INSERT.
        let block = "### INSERT INTO `demo`.`\(test.table)`\n### SET\n###   @1=1 /* INT */"
        let other = "### INSERT INTO `demo`.`unrelated`\n### SET\n###   @1=999 /* INT */"
        let decoded = other + "\n" + test.sql + "\n" + block + "\n" + other
        let lines = try ModifyIndexCases.columnBinlog(decoded, test: test)
        XCTAssertEqual(lines, [test.sql, "### INSERT INTO `demo`.`\(test.table)`", "### SET", "###   @1=1"])
        XCTAssertThrowsError(try ModifyIndexCases.columnBinlog(test.sql + "\n" + other, test: test))
        XCTAssertThrowsError(try ModifyIndexCases.columnBinlog(decoded + "\n" + block, test: test))
        XCTAssertThrowsError(try ModifyIndexCases.columnBinlog(block, test: test))
    }
}
