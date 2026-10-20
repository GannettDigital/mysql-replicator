import Foundation
import MySQLNIO
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class PartitionExpressionTests: XCTestCase {
    func statement(_ sql: String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()))
    }
    func schema(_ values: String) throws -> ApplyTable {
        guard
            case .create(let table, _) = try statement(
                "CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY RANGE(id)(PARTITION p VALUES LESS THAN(" + values
                    + "),PARTITION q VALUES LESS THAN MAXVALUE)")
        else { throw ApplyError("not CREATE") }
        return table
    }
    func testBoundsUseNativeEvaluationBeforeSaving() throws {
        let table = try schema("TO_DAYS('2026-01-01')+2*3")
        XCTAssertTrue(try PartitionBounds.needsEvaluation(table))
        var statements: [String] = []
        let resolved = try PartitionBounds.resolving(table) {
            statements.append($0)
            return "739988"
        }
        XCTAssertEqual(statements, ["(to_days('2026-01-01') + (2 * 3))"])
        XCTAssertEqual(resolved.partitions[0].description, "739988")
        XCTAssertEqual(resolved.partitions[1].description, "MAXVALUE")
        XCTAssertFalse(try PartitionBounds.needsEvaluation(resolved))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(resolved)), resolved)
        XCTAssertEqual(try schema("-0007").partitions[0].description, "-7")
        XCTAssertEqual(try schema("-(--7)").partitions[0].description, "-7")
        XCTAssertEqual(try schema("18446744073709551615").partitions[0].description, "18446744073709551615")
        XCTAssertThrowsError(try PartitionBounds.resolving(table) { _ in throw ApplyError("evaluation interrupted") })
    }
    func testBoundSafetyAndTuples() throws {
        for sql in [
            "id", "stored_function(1)", "rand()", "sleep(2)", "unix_timestamp()", "(SELECT 1)", "@value",
            "1;DROP TABLE t",
        ] { XCTAssertThrowsError(try schema(sql), sql) }
        let tokens = try DDLTokens.lex(Data("(ABS(-1),MAXVALUE),(NULL,FROM_DAYS(739982))".utf8))
        XCTAssertEqual(try partitionDescription(tokens), "(abs((- 1)),MAXVALUE),(NULL,from_days(739982))")
        XCTAssertEqual(
            try schema("EXTRACT(YEAR FROM DATE '2026-01-01')").partitions[0].description,
            "extract(year from cast('2026-01-01' as date))")
        XCTAssertEqual(try PartitionBounds.result(MySQLData(int: 42)), "42")
        XCTAssertEqual(try PartitionBounds.result(.null), "NULL")
        XCTAssertEqual(try PartitionBounds.result(MySQLData(string: "2026-01-01")), "'2026-01-01'")
        XCTAssertThrowsError(try PartitionBounds.result(MySQLData(double: 1.5)))
    }
    func testExchangeValidationModesAndFilters() throws {
        for suffix in ["", " WITH VALIDATION", " WITHOUT VALIDATION"] {
            let sql = "ALTER TABLE poc.t EXCHANGE PARTITION p WITH TABLE otherdb.s" + suffix
            XCTAssertNoThrow(try statement(sql))
            XCTAssertThrowsError(
                try TableFilter(["otherdb.%"]).ignores(
                    .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())))
        }
        for suffix in [
            " WITHOUT", " WITHOUT CHECK", " WITH VALIDATION WITHOUT VALIDATION", " WITHOUT VALIDATION;DROP TABLE t",
        ] {
            XCTAssertThrowsError(try statement("ALTER TABLE t EXCHANGE PARTITION p WITH TABLE s" + suffix))
        }
    }
}

extension DDLTests {
    func testUncertainExchangeKeepsBothTablesAndCannotAutoResume() throws {
        #if os(Linux)
            let f = ResumeTests(name: "fixtures", testClosure: { _ in })
        #else
            let f = ResumeTests()
        #endif
        let path = try f.directory()
        let config = try f.helper.config(path.path, profile: ReplicationProfile.mysql57To84InnoDB.rawValue)
        let db = path.appendingPathComponent("state.sqlite")
        let table = f.helper.tables()[0]
        let other = table.renamed(to: .init(database: table.database, table: "stage"))
        let sql = "ALTER TABLE poc.items EXCHANGE PARTITION p WITH TABLE poc.stage WITHOUT VALIDATION"
        let group = ddlGroup(try f.helper.groups()[0], sql: sql)
        let plan = PreparedDDL(
            statement: try parse(sql), before: table, after: table, sql: sql,
            additional: [.init(before: other, after: other)])
        do {
            let state = try StateStore(configuration: config)
            try state.bindTargetIdentity(f.target)
            try state.running()
            try state.begin(group)
            try state.ddlIntent(plan, event: group.events[1], coordinate: group.start)
            try f.write(
                path, "CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'fixture'); END")
            XCTAssertThrowsError(try state.complete(group, rowCount: 0, ddl: plan))
            try f.write(path, "DROP TRIGGER fail_checkpoint")
            try state.block("uncertain partition exchange")
        }
        XCTAssertEqual(try f.helper.sqlite(db, "SELECT target_sql,status FROM ddl_intents"), [[sql, "PENDING"]])
        XCTAssertEqual(try f.helper.sqlite(db, "SELECT json_array_length(transitions_json) FROM ddl_details"), [["2"]])
        XCTAssertEqual(try f.helper.sqlite(db, "SELECT transactions_applied FROM state"), [["0"]])
        XCTAssertThrowsError(try StateStore(configuration: config, initialize: false))
        XCTAssertThrowsError(try Recovery.inspect(configuration: config)) {
            XCTAssertTrue(String(describing: $0).contains("unresolved DDL"), String(describing: $0))
        }
    }
}
