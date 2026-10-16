import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class TableNameCaseTests: XCTestCase {
    func parse(_ sql: String, _ mode: Int = 1) throws -> DDLStatement {
        try DDLStatement.parse(
            .init(database: "Db", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()), lowerCaseTableNames: mode
        )
    }
    func testNativeTableAndDatabaseCaseDoesNotChangeColumnsOrRoutineNames() throws {
        guard case .create(let table, _) = try parse("CREATE TABLE MIXÉ(ID INT PRIMARY KEY)") else { return XCTFail() }
        XCTAssertEqual(table.database, "db")
        XCTAssertEqual(table.table, "mixé")
        XCTAssertEqual(table.columns[0].name, "ID")
        XCTAssertEqual(try parse("DROP TABLE MIXÉ"), .drop(.init(database: "db", table: "mixé")))
        XCTAssertEqual(try parse("DROP TABLE MIXÉ", 0), .drop(.init(database: "Db", table: "MIXÉ")))
        XCTAssertEqual(try parse("DROP DATABASE Db"), .dropDatabase("db", ifExists: false))
        guard case .object(let object) = try parse("CREATE PROCEDURE Db.Mixed() SELECT 1") else { return XCTFail() }
        XCTAssertEqual(object.name.database, "db")
        XCTAssertEqual(object.name.table, "Mixed")
    }
    func testFilterUsesNativeCaseWithoutUnicodeNormalization() throws {
        let filter = try TableFilter(["DB.MIXÉ%", "Db.é"], lowerCaseTableNames: 1)
        XCTAssertTrue(filter.ignores(database: "db", table: "mixé"))
        XCTAssertFalse(filter.ignores(database: "db", table: "mixé"))
        XCTAssertTrue(filter.ignores(database: "DB", table: "É"))
        XCTAssertFalse(filter.ignores(database: "db", table: "é"))
        XCTAssertTrue(
            try filter.ignores(
                .init(database: "DB", sql: Data("DROP TABLE mixé".utf8), errorCode: 0, statusVariables: Data())))
        XCTAssertThrowsError(try TableFilter([], lowerCaseTableNames: 2))
    }
}
extension ResumeTests {
    func testNameCaseSettingIsPinnedAndLegacyStateRequiresZero() throws {
        let path = try directory()
        let original = try config(path.path, lowerCaseTableNames: 1)
        try seed(original)
        do {
            let resumed = try StateStore(configuration: original, initialize: false)
            try resumed.running()
            try resumed.stopped()
        }
        XCTAssertThrowsError(try StateStore(configuration: config(path.path), initialize: false))
        try write(path, "PRAGMA user_version=9")
        XCTAssertThrowsError(try StateStore(configuration: original, initialize: false))
        let legacy = try directory()
        let zero = try config(legacy.path)
        try seed(zero)
        try write(legacy, "DROP TABLE name_case; PRAGMA user_version=9")
        do {
            let resumed = try StateStore(configuration: zero, initialize: false)
            try resumed.running()
            try resumed.stopped()
        }
        XCTAssertEqual(
            try helper.sqlite(
                legacy.appendingPathComponent("state.sqlite"), "SELECT lower_case_table_names FROM name_case"), [["0"]])
    }
}
