import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class TableAlterTests: XCTestCase {
    func parse(_ sql: String, _ profile: ReplicationProfile = .mysql57To57InnoDB) throws -> DDLStatement {
        try DDLStatement.parse(
            .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()), profile: profile)
    }
    func testTableOptionsUseExactGrammarAndKeepEnginePolicy() throws {
        for option in [
            "COMMENT='a''b'", "ROW_FORMAT=DYNAMIC", "AUTO_INCREMENT=18446744073709551615", "PACK_KEYS=DEFAULT",
            "STATS_PERSISTENT=1", "STATS_SAMPLE_PAGES=DEFAULT", "UNION=()", "KEY_BLOCK_SIZE=8",
        ] {
            XCTAssertNoThrow(try parse("CREATE TABLE t(id INT PRIMARY KEY COMMENT 'key') \(option)"))
            guard case .alter(_, let actions) = try parse("ALTER TABLE t \(option)") else {
                return XCTFail("missing ALTER")
            }
            XCTAssertEqual(actions.count, 1)
        }
        XCTAssertNoThrow(
            try parse("ALTER TABLE t COMMENT='new' ROW_FORMAT=DYNAMIC, AUTO_INCREMENT=20, MODIFY id BIGINT"))
        XCTAssertNoThrow(try parse("CREATE TABLE t(id INT PRIMARY KEY) COMMENT='new', ROW_FORMAT=DYNAMIC"))
        XCTAssertNoThrow(try parse("ALTER TABLE t ENGINE=InnoDB"))
        for sql in [
            "ALTER TABLE t ENGINE=MyISAM", "ALTER TABLE t COMMENT=unknown", "ALTER TABLE t ROW_FORMAT=bad",
            "ALTER TABLE t AUTO_INCREMENT=-1", "ALTER TABLE t AUTO_INCREMENT=18446744073709551616",
            "ALTER TABLE t STATS_PERSISTENT=3", "ALTER TABLE t COMMENT='ok'; DROP TABLE t",
            "CREATE TABLE t(id INT PRIMARY KEY) COMMENT='ok',",
        ] {
            XCTAssertThrowsError(try parse(sql), sql)
        }
    }
    func testAdditionalNativeOptionsAndOrderBoundaries() throws {
        for option in [
            "COMPRESSION='none'", "ENCRYPTION='N'", "CONNECTION='remote'", "PASSWORD=''", "DATA DIRECTORY='/tmp/data'",
            "INDEX DIRECTORY='/tmp/index'", "TABLESPACE innodb_file_per_table STORAGE DISK", "STORAGE MEMORY",
            "INSERT_METHOD=LAST", "UNION=(poc.a,poc.b)",
        ] { XCTAssertNoThrow(try parse("CREATE TABLE t(id INT PRIMARY KEY) " + option), option) }
        for sql in [
            "ALTER TABLE t ORDER BY a DESC,b ASC,ADD c INT", "ALTER TABLE t ADD c INT,WITH VALIDATION",
            "ALTER TABLE t WITHOUT VALIDATION,MODIFY c INT", "ALTER TABLE t ORDER BY a,MAX_ROWS=10",
        ] { XCTAssertNoThrow(try parse(sql), sql) }
        for sql in [
            "ALTER TABLE t ORDER BY", "ALTER TABLE t ORDER BY a,", "ALTER TABLE t WITH",
            "ALTER TABLE t DATA DIRECTORY=123",
        ] { XCTAssertThrowsError(try parse(sql), sql) }
        for option in [
            "AUTOEXTEND_SIZE=64", "ENGINE_ATTRIBUTE='{}'", "SECONDARY_ENGINE_ATTRIBUTE='{}'", "SECONDARY_ENGINE=NULL",
        ] {
            XCTAssertThrowsError(try parse("ALTER TABLE t " + option))
            XCTAssertNoThrow(try parse("ALTER TABLE t " + option, .mysql57To84InnoDB))
        }
    }
    func testCrossFamilyPredictionRetainsKeysAndPlacement() throws {
        let original = ApplyTable(
            database: "poc", table: "t",
            columns: [
                .init(name: "id", type: "int", nullable: false, collation: nil),
                .init(name: "n", type: "int", nullable: true, collation: nil),
            ], primaryKey: "id")
        let text = ApplyColumn(name: "id", type: "varchar(30)", nullable: true, collation: "utf8mb4_bin")
        let changed = try original.modifying(text, placement: .after("n"))
        XCTAssertEqual(changed.primaryKeyColumns, ["id"])
        XCTAssertEqual(changed.columns.map(\.name), ["n", "id"])
        XCTAssertFalse(changed.columns[1].nullable)
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(changed)), changed)
        XCTAssertThrowsError(
            try original.modifying(.init(name: "id", type: "json", nullable: true, collation: nil), placement: nil))
    }
}
