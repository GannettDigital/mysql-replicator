import Foundation
import MySQLSyntax
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ColumnPartitionBoundsTests: XCTestCase {
    func table(_ definition: String) throws -> ApplyTable {
        guard
            case .create(let table, _) = try DDLStatement.parse(
                .init(database: "poc", sql: Data(definition.utf8), errorCode: 0, statusVariables: Data()))
        else { throw ApplyError("not CREATE") }
        return table
    }
    func testDecodedLiteralsKeepConnectionBytes() throws {
        let tokens = [DDLToken(text: "'é'", literal: "é", literalBytes: Data([0xe9]))]
        let preserved = try PartitionBounds.preservingLiteralBytes(tokens, charset: "latin1")
        XCTAssertEqual(try PartitionBounds.canonical(preserved), "_latin1 X'e9'")
        let binary = ApplyColumn(name: "v", type: "varbinary(10)", nullable: false, collation: nil)
        XCTAssertEqual(
            ColumnPartitionBounds.resultSQL("_latin1 X'e9'", column: binary), "CAST(_latin1 X'e9' AS BINARY)")
        XCTAssertEqual(ColumnPartitionBounds.resultSQL("1", column: nil), "1")
        XCTAssertEqual(try PartitionBounds.canonical(DDLTokens.lex(Data("X''".utf8))), "X''")
    }
    func testBytesAndCharsetIntroducers() throws {
        for (input, expected) in [
            ("X'80ff'", "X'80ff'"), ("_latin1 X'E9'", "_latin1 X'e9'"), ("_binary 0x0080ff", "_binary X'0080ff'"),
            ("_utf8mb4 'é'", "_utf8mb4 X'c3a9'"),
        ] {
            let expression = try PartitionBounds.parse(DDLTokens.lex(Data(input.utf8)))
            XCTAssertEqual(try PartitionBounds.evaluationSQL(expression), expected)
        }
        XCTAssertThrowsError(try PartitionBounds.evaluationSQL(.introduced("_utf8;drop", .bytes(Data()))))
        XCTAssertThrowsError(try PartitionBounds.evaluationSQL(.introduced("_utf8", .number("1"))))
    }
    func testRawNativeBinaryMetadataAndEscapes() throws {
        let schema = try table(
            "CREATE TABLE t(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN(X'80ff',X'005c0a27'))"
        )
        var metadata = Data(
            "CREATE TABLE `t` (`v` varbinary(10)) /*!50500 PARTITION BY LIST COLUMNS(`v`)(PARTITION `p` VALUES IN('"
                .utf8)
        metadata.append(contentsOf: [0x80, 0xff])
        metadata.append(Data("','\\0\\\\\\n''')) */".utf8))
        let native84 = Data(
            "CREATE TABLE `t` (`v` varbinary(10)) /*!50500 PARTITION BY LIST COLUMNS(`v`)(PARTITION p VALUES IN(_binary 0x80FF,_binary 0x005C0A27)) */"
                .utf8)
        let result = try ColumnPartitionBounds.metadata(metadata, table: schema)
        XCTAssertEqual(try ColumnPartitionBounds.metadata(native84, table: schema), result)
        XCTAssertEqual(result[0].description, "X'80ff',X'005c0a27'")
        var saved = schema
        saved.partitions = result
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(saved)), saved)
    }
    func testColumnOrderAndOriginalDateSpelling() throws {
        let schema = try table(
            "CREATE TABLE t(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY RANGE COLUMNS(d,id)(PARTITION p VALUES LESS THAN('20260101',ABS(-10)),PARTITION q VALUES LESS THAN(MAXVALUE,MAXVALUE))"
        )
        var columns: [String] = []
        let resolved = try ColumnPartitionBounds.resolving(schema) { value, column in
            columns.append(column!.name)
            return PartitionBounds.literal(value) ?? "10"
        }
        XCTAssertEqual(columns, ["d", "id"])
        XCTAssertEqual(resolved.partitions[0].description, "'20260101',10")
        XCTAssertEqual(resolved.partitions[1].description, "MAXVALUE,MAXVALUE")
    }
    func testListTuplesAndMissingColumnsFail() throws {
        let schema = try table(
            "CREATE TABLE t(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY LIST COLUMNS(d,id)(PARTITION p VALUES IN(('20260101',1),('20260102',2)))"
        )
        XCTAssertEqual(
            try ColumnPartitionBounds.resolving(schema) { value, _ in PartitionBounds.literal(value)! }.partitions[0]
                .description, "('20260101',1),('20260102',2)")
        var invalid = ApplyTable(database: schema.database, table: schema.table, columns: [], primaryKeyColumns: [])
        invalid.partitions = schema.partitions
        XCTAssertThrowsError(try ColumnPartitionBounds.resolving(invalid) { _, _ in "0" })
        invalid = schema
        invalid.partitions[0].description = "('20260101')"
        XCTAssertThrowsError(try ColumnPartitionBounds.resolving(invalid) { _, _ in "0" })
    }
}
