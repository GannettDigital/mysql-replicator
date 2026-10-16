import Foundation
import MySQLNIO
import NIOCore
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class FloatingTypeTests: XCTestCase {
    func parse(_ sql: String, mode: UInt64 = 0) throws -> DDLStatement {
        var parser = try DDLParser(Data(sql.utf8), database: "poc", sqlMode: mode)
        return try parser.parse()
    }
    func testBinaryBindingsReadsAndExactComparisons() throws {
        let values: [DecodedValue] = [
            .float32(0x3dcc_cccd), .float32(1), .float32(0x7f7f_ffff), .float32(0x8000_0000),
            .float64(0x3fb9_9999_9999_999a), .float64(1), .float64(0x7fef_ffff_ffff_ffff),
            .float64(0x8000_0000_0000_0000),
        ]
        for value in values {
            let binding = try FloatingPointSQL.bind(value)
            let single = binding.type == .float
            let type = try DMLColumnType(single ? "float" : "double")
            try type.validate(value)
            XCTAssertEqual(binding.buffer?.readableBytes, single ? 4 : 8)
            XCTAssertFalse(binding.isUnsigned)
            XCTAssertEqual(try FloatingPointSQL.read(binding, type: type), value)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            XCTAssertEqual((json["ieeeBits"] as? String)?.count, single ? 8 : 16)
        }
        let binding = try FloatingPointSQL.bind(.float32(0x3dcc_cccd))
        XCTAssertEqual(Array(binding.buffer!.readableBytesView), [0xcd, 0xcc, 0xcc, 0x3d])
        var packet = MySQLPacket()
        try MySQLProtocol.COM_STMT_EXECUTE(statementID: 1, flags: [], values: [binding]).encode(
            to: &packet, capabilities: [])
        XCTAssertEqual(Array(packet.payload.readableBytesView.suffix(6)), [4, 0, 0xcd, 0xcc, 0xcc, 0x3d])
        XCTAssertFalse(exactImage([.float32(0)], [.float32(0x8000_0000)]))
        XCTAssertFalse(exactImage([.float64(0x3ff0_0000_0000_0000)], [.float64(0x3ff0_0000_0000_0001)]))
        XCTAssertThrowsError(try FloatingPointSQL.bind(.float32(0x7f80_0000)))
        XCTAssertThrowsError(try FloatingPointSQL.bind(.float64(0x7ff8_0000_0000_0001)))
        XCTAssertThrowsError(try FloatingPointSQL.read(binding, type: DMLColumnType("double")))
        XCTAssertThrowsError(try DMLColumnType("float unsigned").validate(.float32(0xbf80_0000)))
        try DMLColumnType("float unsigned").validate(.float32(0x8000_0000))
    }
    func testDDLFormsDefaultsAndWireMetadata() throws {
        for mode: UInt64 in [0, 1] {
            guard
                case .create(let table, _) = try parse(
                    "CREATE TABLE f(id DOUBLE PRECISION PRIMARY KEY, a FLOAT(24) DEFAULT 1.25e-1, b FLOAT(25), c REAL, d FLOAT UNSIGNED DEFAULT 0, e DOUBLE DEFAULT -1.25E+12)",
                    mode: mode)
            else { return XCTFail("not CREATE") }
            XCTAssertEqual(
                table.columns.map(\.type),
                ["double", "float", "double", mode == 0 ? "double" : "float", "float unsigned", "double"])
            XCTAssertEqual(table.columns[1].defaultValue, "0.125")
            XCTAssertEqual(table.columns[5].defaultValue, "-1250000000000.0")
            try table.validate()
            let plan = try DMLSQLPlan(table)
            XCTAssertFalse(plan.select.contains("CAST("))
            XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(table)), table)
        }
        for definition in [
            "FLOAT(54)", "FLOAT(1,2)", "DOUBLE(256,2)", "DOUBLE(10,31)", "DOUBLE(53)", "DOUBLE DEFAULT 1e309",
        ] {
            XCTAssertThrowsError(try parse("CREATE TABLE f(id INT PRIMARY KEY,v " + definition + ")"), definition)
        }
        let original = "CREATE TABLE f(id INT PRIMARY KEY,v FLOAT DEFAULT 1.23456789)"
        var parser = try DDLParser(Data(original.utf8), database: "poc")
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns[1].defaultValue, "1.23457")
        XCTAssertEqual(parser.translatedSQL(Data(original.utf8)), original)
        XCTAssertEqual(
            try TargetColumnMetadata.defaultValue("1.23457", type: "float", mysql84: false),
            table.columns[1].defaultValue)
        XCTAssertEqual(
            try TargetColumnMetadata.defaultValue("1.23457", type: "float", mysql84: true),
            table.columns[1].defaultValue)
        XCTAssertNotEqual(Float(1.23456789).bitPattern, Float(1.23457).bitPattern)
        // Schema presentation can lose bits. The DML path must not lose them.
        let exact = DecodedValue.float32(Float(1.23456789).bitPattern)
        XCTAssertEqual(try FloatingPointSQL.read(FloatingPointSQL.bind(exact), type: DMLColumnType("float")), exact)
        for (literal, expected) in [("1e-100", "0.0"), ("-0", "0.0"), ("1e40", "3.40282e+38")] {
            XCTAssertEqual(try normalizedDefault(literal, type: DMLColumnType("float")), expected)
        }
        for typeName in ["float", "double", "float unsigned", "double unsigned"] {
            let type = try DMLColumnType(typeName)
            let single = type.base == "float"
            var wire = WireColumn(
                interpretation: single ? .float32 : .float64, type: single ? 4 : 5, maximumBytes: 0, nullable: true,
                collation: 0, primaryKey: false, name: nil, metadata: Data([single ? 4 : 8]), isUnsigned: type.unsigned)
            XCTAssertTrue(type.matches(wire))
            wire.isUnsigned = nil
            XCTAssertTrue(type.matches(wire, legacyMetadata: true))
            XCTAssertFalse(type.matches(wire))
            for mysql84 in [false, true] {
                XCTAssertEqual(
                    try TargetColumnMetadata.defaultValue("1.25e-1", type: typeName, mysql84: mysql84), "0.125")
            }
        }
    }
    func testFixedScaleDDLDefaultsAndRowBits() throws {
        let sql =
            "CREATE TABLE f(id FLOAT(10,2) PRIMARY KEY,a DOUBLE(20,6) DEFAULT -1.23456789,b FLOAT(30,20) DEFAULT 0.1,c DOUBLE(200,0) DEFAULT 1e199)"
        guard case .create(let table, _) = try parse(sql) else { return XCTFail("not CREATE") }
        try table.validate()
        XCTAssertEqual(table.columns.map(\.type), ["float(10,2)", "double(20,6)", "float(30,20)", "double(200,0)"])
        XCTAssertEqual(table.columns[1].defaultValue, "-1.234568")
        XCTAssertEqual(table.columns[2].defaultValue, String(Double(Float(0.1))))
        for mysql84 in [false, true] {
            XCTAssertEqual(
                try TargetColumnMetadata.defaultValue("0.10000000149011612000", type: "float(30,20)", mysql84: mysql84),
                table.columns[2].defaultValue)
            XCTAssertEqual(
                try TargetColumnMetadata.defaultValue("-1.234568", type: "double(20,6)", mysql84: mysql84),
                table.columns[1].defaultValue)
        }
        for name in ["float(10,2)", "double(255,30)", "float(10,2) unsigned"] {
            let type = try DMLColumnType(name)
            let single = type.base == "float"
            let value: DecodedValue = single ? .float32(Float(1.23).bitPattern) : .float64(Double(1.23).bitPattern)
            XCTAssertEqual(try FloatingPointSQL.read(FloatingPointSQL.bind(value), type: type), value)
            let wire = WireColumn(
                interpretation: single ? .float32 : .float64, type: single ? 4 : 5, maximumBytes: 0, nullable: true,
                collation: 0, primaryKey: false, name: nil, metadata: Data([single ? 4 : 8]), isUnsigned: type.unsigned)
            XCTAssertTrue(type.matches(wire))
        }
        for (value, expected) in [("1.235", "1.24"), ("-0.0001", "0.0"), ("1e10", "99999999.99")] {
            XCTAssertEqual(try normalizedDefault(value, type: DMLColumnType("double(10,2)")), expected)
        }
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(table)), table)
    }

    func testFixedScaleEndpointWritesKeepStoredKeyPredicates() throws {
        guard case .create(let table, _) = try parse("CREATE TABLE f(id FLOAT(8,2) PRIMARY KEY,v FLOAT(8,2) UNSIGNED)")
        else { return XCTFail("not CREATE") }
        let plan = try DMLSQLPlan(table)
        XCTAssertEqual(
            plan.insert,
            "INSERT INTO `poc`.`f` (`id`,`v`) VALUES (LEAST(GREATEST(?,-999999.99),999999.99),LEAST(GREATEST(?,0),999999.99))"
        )
        XCTAssertTrue(plan.update.hasSuffix("WHERE (`id`+0e0)=?"))
        XCTAssertEqual(plan.delete, "DELETE FROM `poc`.`f` WHERE (`id`+0e0)=?")
        XCTAssertEqual(plan.insertSQL(expressions: [["?", "?"]]), plan.insert)
        XCTAssertEqual(plan.updateSQL(expressions: ["?", "?"]), plan.update)
        let type = try DMLColumnType("float(8,2)")
        try type.validate(.float32(Float(1_000_000).bitPattern))
        XCTAssertThrowsError(try type.validate(.float32(Float(1_000_001).bitPattern)))
    }

}
