import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class UnicodeIdentifierTests: XCTestCase {
    func testIdentifierLengthCountsScalarsNotBytesOrGraphemes() throws {
        XCTAssertNoThrow(try quoted(String(repeating: "中", count: 64)))
        XCTAssertThrowsError(try quoted(String(repeating: "中", count: 65)))
        XCTAssertNoThrow(try quoted(String(repeating: "e\u{0301}", count: 32)))
        XCTAssertThrowsError(try quoted(String(repeating: "e\u{0301}", count: 33)))
        XCTAssertEqual(try quoted("a`中"), "`a``中`")
        XCTAssertThrowsError(try quoted("a\0b"))
    }
    func testSupplementaryIdentifiersUseNativeStoredNamesWithoutRewritingSQL() throws {
        let sql = "CREATE TABLE 😀(id INT PRIMARY KEY,`😀` INT)"
        var parser = try DDLParser(Data(sql.utf8), database: "poc")
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("expected CREATE") }
        XCTAssertEqual(table.table, "?")
        XCTAssertEqual(table.columns[1].name, "?")
        XCTAssertEqual(parser.translatedSQL(Data(sql.utf8)), sql)
        let filter = try TableFilter(["poc.?"])
        XCTAssertTrue(
            try filter.ignores(.init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())))
    }
    func testUnicodeColumnsIndexesAndTableNamesRemainDistinct() throws {
        var parser = try DDLParser(
            Data(
                "CREATE TABLE 库.中(id INT PRIMARY KEY,`é` INT,`e\u{0301}` INT,ſelect INT,KEY `é`(`é`),KEY `e\u{0301}`(`e\u{0301}`))"
                    .utf8), database: nil)
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("expected CREATE") }
        try table.validate()
        XCTAssertEqual(table.columns.count, 4)
        XCTAssertEqual(table.secondaryIndexes.count, 2)
        let second = table.renamed(to: .init(database: "库", table: "e\u{0301}"))
        let first = table.renamed(to: .init(database: "库", table: "é"))
        let changes = try TableRename.transitions(
            [.init(from: .init(database: "库", table: "é"), to: .init(database: "库", table: "new"))],
            schemas: [first.identity: first, second.identity: second])
        XCTAssertEqual(changes.compactMap(\.after).count, 2)
        XCTAssertTrue(changes.contains { $0.after?.identity == second.identity })
    }
    func testUnicodeFiltersPreserveScalarAndByteIdentity() throws {
        let filter = try TableFilter(["库.é", "库.临时%"])
        XCTAssertTrue(filter.ignores(database: "库", table: "é"))
        XCTAssertFalse(filter.ignores(database: "库", table: "e\u{0301}"))
        XCTAssertTrue(filter.ignores(database: "库", table: "临时表"))
        XCTAssertTrue(
            try filter.ignores(
                .init(database: "库", sql: Data("CREATE TABLE 临时表(id INT)".utf8), errorCode: 0, statusVariables: Data()))
        )
        XCTAssertFalse(TableFilter.matches("库._", "库.e\u{0301}"))
        XCTAssertTrue(TableFilter.matches("库.__", "库.e\u{0301}"))
    }
    func testNonUTF8ClientIsNotMisreadAsUTF8() throws {
        func query(_ client: UInt8) -> QueryControl {
            let status =
                Data([1]) + Data(repeating: 0, count: 8) + Data([4, client, 0, client, 0, client, 0, 18, 45, 0])
            return .init(
                database: "poc", sql: Data("CREATE TABLE é(id INT PRIMARY KEY)".utf8), errorCode: 0,
                statusVariables: status)
        }
        XCTAssertNoThrow(try DDLStatement.parse(query(45)))
        XCTAssertNoThrow(try DDLStatement.parse(query(33)))
        XCTAssertThrowsError(try DDLStatement.parse(query(8))) { error in
            XCTAssertTrue(String(describing: error).contains("character_set_client=ID 8"))
        }
        XCTAssertThrowsError(try TableFilter(["poc.%"]).ignores(query(8)))
    }
}
