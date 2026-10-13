import XCTest
import Foundation
import MySQLNIO
import NIOCore
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class FloatingTypeTests: XCTestCase {
    func parse(_ sql:String,mode:UInt64=0) throws -> DDLStatement {
        var parser=try DDLParser(Data(sql.utf8),database:"poc",sqlMode:mode)
        return try parser.parse()
    }
    func testBinaryBindingsReadsAndExactComparisons() throws {
        let values:[DecodedValue]=[.float32(0x3dcccccd),.float32(1),.float32(0x7f7fffff),.float32(0x80000000),.float64(0x3fb999999999999a),.float64(1),.float64(0x7fefffffffffffff),.float64(0x8000000000000000)]
        for value in values {
            let binding=try FloatingPointSQL.bind(value)
            let single=binding.type == .float
            let type=try DMLColumnType(single ? "float" : "double")
            try type.validate(value)
            XCTAssertEqual(binding.buffer?.readableBytes,single ? 4 : 8)
            XCTAssertFalse(binding.isUnsigned)
            XCTAssertEqual(try FloatingPointSQL.read(binding,type:type),value)
            let json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
            XCTAssertEqual((json["ieeeBits"] as? String)?.count,single ? 8 : 16)
        }
        let binding=try FloatingPointSQL.bind(.float32(0x3dcccccd))
        XCTAssertEqual(Array(binding.buffer!.readableBytesView),[0xcd,0xcc,0xcc,0x3d])
        var packet=MySQLPacket()
        try MySQLProtocol.COM_STMT_EXECUTE(statementID:1,flags:[],values:[binding]).encode(to:&packet,capabilities:[])
        XCTAssertEqual(Array(packet.payload.readableBytesView.suffix(6)),[4,0,0xcd,0xcc,0xcc,0x3d])
        XCTAssertFalse(exactImage([.float32(0)],[.float32(0x80000000)]))
        XCTAssertFalse(exactImage([.float64(0x3ff0000000000000)],[.float64(0x3ff0000000000001)]))
        XCTAssertThrowsError(try FloatingPointSQL.bind(.float32(0x7f800000)))
        XCTAssertThrowsError(try FloatingPointSQL.bind(.float64(0x7ff8000000000001)))
        XCTAssertThrowsError(try FloatingPointSQL.read(binding,type:DMLColumnType("double")))
        XCTAssertThrowsError(try DMLColumnType("float unsigned").validate(.float32(0xbf800000)))
        try DMLColumnType("float unsigned").validate(.float32(0x80000000))
    }
    func testDDLFormsDefaultsAndWireMetadata() throws {
        for mode:UInt64 in [0,1] {
            guard case .create(let table,_) = try parse("CREATE TABLE f(id DOUBLE PRECISION PRIMARY KEY, a FLOAT(24) DEFAULT 1.25e-1, b FLOAT(25), c REAL, d FLOAT UNSIGNED DEFAULT 0, e DOUBLE DEFAULT -1.25E+12)",mode:mode) else { return XCTFail("not CREATE") }
            XCTAssertEqual(table.columns.map(\.type),["double","float","double",mode == 0 ? "double" : "float","float unsigned","double"])
            XCTAssertEqual(table.columns[1].defaultValue,"0.125")
            XCTAssertEqual(table.columns[5].defaultValue,"-1250000000000.0")
            try table.validate()
            let plan=try DMLSQLPlan(table)
            XCTAssertFalse(plan.select.contains("CAST("))
            XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        }
        for definition in ["FLOAT(54)","FLOAT(10,2)","DOUBLE(10,2)","DOUBLE(53)","FLOAT ZEROFILL","DOUBLE DEFAULT 1e309"] {
            XCTAssertThrowsError(try parse("CREATE TABLE f(id INT PRIMARY KEY,v "+definition+")"),definition)
        }
        let original="CREATE TABLE f(id INT PRIMARY KEY,v FLOAT DEFAULT 1.23456789)"
        var parser=try DDLParser(Data(original.utf8),database:"poc")
        guard case .create(let table,_) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns[1].defaultValue,"1.23457")
        XCTAssertEqual(parser.translatedSQL(Data(original.utf8)),original)
        XCTAssertEqual(try TargetColumnMetadata.defaultValue("1.23457",type:"float",mysql84:false),table.columns[1].defaultValue)
        XCTAssertEqual(try TargetColumnMetadata.defaultValue("1.23457",type:"float",mysql84:true),table.columns[1].defaultValue)
        XCTAssertNotEqual(Float(1.23456789).bitPattern,Float(1.23457).bitPattern)
        // Schema presentation can lose bits. The DML path must not lose them.
        let exact=DecodedValue.float32(Float(1.23456789).bitPattern)
        XCTAssertEqual(try FloatingPointSQL.read(FloatingPointSQL.bind(exact),type:DMLColumnType("float")),exact)
        for (literal,expected) in [("1e-100","0.0"),("-0","0.0"),("1e40","3.40282e+38")] {
            XCTAssertEqual(try normalizedDefault(literal,type:DMLColumnType("float")),expected)
        }
        for typeName in ["float","double","float unsigned","double unsigned"] {
            let type=try DMLColumnType(typeName), single=type.base == "float"
            var wire=WireColumn(interpretation:single ? .float32 : .float64,type:single ? 4 : 5,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([single ? 4 : 8]),isUnsigned:type.unsigned)
            XCTAssertTrue(type.matches(wire))
            wire.isUnsigned=nil
            XCTAssertTrue(type.matches(wire,legacyMetadata:true)); XCTAssertFalse(type.matches(wire))
            for mysql84 in [false,true] {
                XCTAssertEqual(try TargetColumnMetadata.defaultValue("1.25e-1",type:typeName,mysql84:mysql84),"0.125")
            }
        }
    }
}
