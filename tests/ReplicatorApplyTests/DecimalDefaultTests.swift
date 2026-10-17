import Foundation
import XCTest

@testable import ReplicatorApply

final class DecimalDefaultTests: XCTestCase {
    func testNativeDefaultsKeepLiteralKindUntilResolution() throws {
        for (literal, value, numeric) in [
            ("1.235", "1.235", true), ("-1.235", "-1.235", true), ("1.005e0", "1.005e0", true),
            ("'1.005e0'", "1.005e0", false), ("' 1.25 '", " 1.25 ", false),
        ] {
            var parser = try DDLParser(
                Data("CREATE TABLE t(id INT PRIMARY KEY,d DECIMAL(8,2) DEFAULT \(literal))".utf8), database: "poc")
            guard case .create(let table, _) = try parser.parse() else { return XCTFail("not CREATE") }
            XCTAssertEqual(table.columns[1].defaultValue, value)
            XCTAssertEqual(table.columns[1].numericDefaultLiteral, numeric)
            XCTAssertThrowsError(try table.validate(), "unresolved metadata must not become saved schema")
        }
    }
    func testCanonicalStoredDefaultsKeepExistingSchemaFormat() throws {
        let column = ApplyColumn(
            name: "d", type: "decimal(8,2) unsigned zerofill", nullable: true, collation: nil, defaultValue: "10.00")
        try column.validate()
        XCTAssertEqual(try normalizedDefault("000010.00", type: DMLColumnType(column)), column.defaultValue)
        let data = try JSONEncoder().encode(column)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("numericDefaultLiteral"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self, from: data), column)
        var parser = try DDLParser(
            Data("CREATE TABLE t(id INT PRIMARY KEY,d DECIMAL(8,2) DEFAULT NULL)".utf8), database: "poc")
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertNil(table.columns[1].numericDefaultLiteral)
        try table.validate()
    }
}
