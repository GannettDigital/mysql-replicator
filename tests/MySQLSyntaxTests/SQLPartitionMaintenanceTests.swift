import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLPartitionMaintenanceTests: XCTestCase {
    func parse(_ sql: String) throws -> SQLPartitionMaintenance { try .parse(SQLLexer.lex(Data(sql.utf8))) }
    func testNativeOperationsSelectionsAndOptions() throws {
        for name in ["REBUILD", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECK"] {
            let all = try parse(name + " PARTITION ALL")
            XCTAssertEqual(all.operation.rawValue, name)
            XCTAssertTrue(all.names.isEmpty)
            XCTAssertEqual(try parse(name + " PARTITION p0,`p``1`").names, ["p0", "p`1"])
        }
        XCTAssertTrue(try parse("REBUILD PARTITION LOCAL ALL").local)
        XCTAssertTrue(try parse("OPTIMIZE PARTITION p0 NO_WRITE_TO_BINLOG").local)
        XCTAssertEqual(
            try parse("CHECK PARTITION ALL QUICK FAST MEDIUM EXTENDED CHANGED FOR UPGRADE").options,
            ["QUICK", "FAST", "MEDIUM", "EXTENDED", "CHANGED", "FOR UPGRADE"])
        XCTAssertEqual(
            try parse("REPAIR PARTITION NO_WRITE_TO_BINLOG p0 QUICK EXTENDED USE_FRM").options,
            ["QUICK", "EXTENDED", "USE_FRM"])
    }
    func testInvalidMaintenanceAndNativeSuffixBoundaries() throws {
        for sql in [
            "", "CHECK TABLE t", "ANALYZE PARTITION", "REBUILD PARTITION LOCAL", "REPAIR PARTITION p0,",
            "REBUILD PARTITION 'p0'", "CHECK PARTITION ALL FOR", "CHECK PARTITION ALL FOR x",
            "CHECK PARTITION ALL;DROP TABLE t", "ANALYZE PARTITION ALL QUICK", "REBUILD PARTITION ALL UNKNOWN",
            "REPAIR PARTITION ALL CHANGED",
        ] { XCTAssertThrowsError(try parse(sql), sql) }
        for sql in [
            "CREATE TABLE t(id INT PRIMARY KEY COMMENT 'PARTITION BY KEY ALGORITHM=1(id)')",
            "CREATE TABLE `PARTITION` (`BY` INT)",
        ] {
            XCTAssertNil(try SQLPartitionClause.fromCreateTable(SQLLexer.lex(Data(sql.utf8))))
        }
        let sql =
            "CREATE TABLE t(id INT PRIMARY KEY) /*!50100 PARTITION BY KEY */ /*!50611 ALGORITHM = 1 */ /*!50100 (id) PARTITIONS 2 */"
        let tokens = try SQLLexer.lex(Data(sql.utf8), nativeMetadata: true)
        XCTAssertEqual(try SQLPartitionClause.fromCreateTable(tokens)?.method.algorithm, 1)
        XCTAssertThrowsError(try SQLLexer.lex(Data(sql.utf8)))
        for sql in [
            "CREATE TABLE t(id INT", "CREATE TABLE t(id INT))",
            "CREATE TABLE t(id INT) PARTITION BY KEY(id) PARTITIONS 2 EXTRA",
        ] { XCTAssertThrowsError(try SQLPartitionClause.fromCreateTable(SQLLexer.lex(Data(sql.utf8)))) }
    }
}
