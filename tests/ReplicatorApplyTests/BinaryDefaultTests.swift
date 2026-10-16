import Foundation
import XCTest

@testable import ReplicatorApply

final class BinaryDefaultTests: XCTestCase {
    func testLiteralsRetainBytesBeforeNativePadding() throws {
        var parser = try DDLParser(
            Data(
                "CREATE TABLE t(id INT PRIMARY KEY,b BINARY(5) DEFAULT X'ff0001',v VARBINARY(5) DEFAULT 0xFF00,e BINARY(0) DEFAULT X'',c CHAR(4) CHARACTER SET binary DEFAULT B'11111111',s BINARY(4) DEFAULT 'hi')"
                    .utf8), database: "poc")
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertEqual(
            table.columns.dropFirst().map(\.binaryDefaultBytes),
            [Data([255, 0, 1]), Data([255, 0]), Data(), Data([255]), Data("hi".utf8)])
        XCTAssertTrue(table.columns.dropFirst().allSatisfy { $0.defaultValue == nil && $0.hasDefaultValue })
    }
    func testNumericLiteralReachesNativeConversionUnchanged() throws {
        var parser = try DDLParser(
            Data("CREATE TABLE t(id INT PRIMARY KEY,b BINARY(8) DEFAULT 1e2)".utf8), database: "poc")
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns[1].numericDefaultLiteral, true)
        XCTAssertEqual(table.columns[1].defaultValue, "1e2")
        XCTAssertNil(table.columns[1].binaryDefaultBytes)
        XCTAssertThrowsError(try table.validate())
    }
    func testExactDefaultBytesAndLegacyUTF8SchemaShape() throws {
        let input = ApplyColumn(name: "b", type: "binary(5)", nullable: true, collation: nil)
        let bytes = Data([255, 0, 1, 0, 0])
        let column = try BinaryDefaultMetadata.resolved(input, bytes: bytes)
        XCTAssertEqual(column.binaryDefaultBytes, bytes)
        XCTAssertNil(column.defaultValue)
        XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self, from: JSONEncoder().encode(column)), column)
        XCTAssertThrowsError(try BinaryDefaultMetadata.resolved(input, bytes: Data([255])))
        let old = ApplyColumn(name: "b", type: "binary(5)", nullable: true, collation: nil, defaultValue: "hi\0\0\0")
        XCTAssertEqual(try BinaryDefaultMetadata.resolved(input, bytes: Data("hi\0\0\0".utf8)), old)
        let empty = try BinaryDefaultMetadata.resolved(
            ApplyColumn(name: "e", type: "binary(0)", nullable: true, collation: nil), bytes: Data())
        XCTAssertEqual(empty.defaultValue, "")
        XCTAssertTrue(empty.hasDefaultValue)
        var invalid = column
        invalid.type = "int"
        XCTAssertThrowsError(try invalid.validate())
    }
}
