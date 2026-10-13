import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class BitTypeTests: XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testWidthsDefaultsAndExactSchemaChecks() throws {
        for width in [1,7,8,9,63,64] {
            let type=try DMLColumnType("bit(\(width))"),maximum=UInt64.max >> (64-width)
            try type.validate(.unsigned(maximum)); try type.validate(.unsigned(0))
            XCTAssertThrowsError(try type.validate(.signed(0)))
            if width < 64 { XCTAssertThrowsError(try type.validate(.unsigned(maximum+1))) }
            var wire=WireColumn(interpretation:.unsigned,type:16,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([UInt8(width%8),UInt8(width/8)]))
            XCTAssertTrue(type.matches(wire)); XCTAssertTrue(type.matches(wire,legacyMetadata:true))
            wire.metadata=Data([UInt8((width == 64 ? 63 : width+1)%8),UInt8((width == 64 ? 63 : width+1)/8)])
            XCTAssertFalse(type.matches(wire,legacyMetadata:true))
            let expected="b'"+String(maximum,radix:2)+"'"
            XCTAssertEqual(try normalizedDefault(String(maximum),type:type),expected)
            for mysql84 in [false,true] {
                XCTAssertEqual(try TargetColumnMetadata.defaultValue("b'000"+String(maximum,radix:2)+"'",type:"bit(\(width))",mysql84:mysql84),expected)
            }
        }
        for type in ["bit(0)","bit(65)","bit(8,1)","bit unsigned"] { XCTAssertThrowsError(try DMLColumnType(type)) }
        XCTAssertEqual(try DMLColumnType("bit").bitWidth,1)
        XCTAssertThrowsError(try normalizedDefault("2",type:DMLColumnType("bit")))
        XCTAssertThrowsError(try normalizedDefault("b'102'",type:DMLColumnType("bit(8)")))
    }
    func testDDLKeyPlansAndSavedMetadata() throws {
        guard case .create(let table,_) = try parse("CREATE TABLE bits(id BIT(64) PRIMARY KEY, a BIT DEFAULT b'1', b BIT(9) DEFAULT 0b100000001, c BIT(8) DEFAULT 255)") else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns.map(\.type),["bit(64)","bit(1)","bit(9)","bit(8)"])
        XCTAssertEqual(table.columns.map(\.defaultValue),[nil,"b'1'","b'100000001'","b'11111111'"])
        try table.validate()
        let plan=try DMLSQLPlan(table)
        XCTAssertTrue(plan.select.contains("CAST(`id` AS UNSIGNED) AS `id`"))
        XCTAssertTrue(plan.select.contains("WHERE `id`=?"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        try DMLTablePlan(table).validate([.unsigned(UInt64.max),.unsigned(1),.unsigned(511),.null])
        XCTAssertThrowsError(try parse("CREATE TABLE t(id BIT(1) PRIMARY KEY DEFAULT b'10')"))
        XCTAssertThrowsError(try parse("CREATE TABLE t(id BIT PRIMARY KEY AUTO_INCREMENT)"))
        XCTAssertThrowsError(try parse("CREATE TABLE t(id BIT DEFAULT b'102')"))
        guard case .add(_,let column,_) = try parse("ALTER TABLE bits ADD n BIT(63) DEFAULT b'0'") else { return XCTFail("not ADD") }
        XCTAssertEqual(column.type,"bit(63)"); XCTAssertEqual(column.defaultValue,"b'0'")
        let widened=try table.modifying(ApplyColumn(name:"b",type:"bit(64)",nullable:true,collation:nil),placement:nil)
        XCTAssertEqual(widened.columns[2].type,"bit(64)")
        // The diagnostic format stores UInt64 as decimal text, with no Double conversion.
        let json=String(decoding:try JSONEncoder().encode(DecodedValue.unsigned(UInt64.max)),as:UTF8.self)
        XCTAssertTrue(json.contains("18446744073709551615"))
    }
}
