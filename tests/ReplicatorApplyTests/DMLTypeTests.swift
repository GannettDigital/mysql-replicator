import XCTest
import Foundation
@testable import ReplicatorCodec
@testable import ReplicatorApply

final class DMLTypeTests: XCTestCase {
    func testSmallIntegerBoundariesAndExactDecimals() throws {
        for (type,bits) in [("tinyint",8),("smallint",16),("mediumint",24)] {
            let signed=try DMLColumnType(type), unsigned=try DMLColumnType(type+" unsigned")
            let half=Int64(1) << (bits-1), maximum=(UInt64(1) << bits)-1
            try signed.validate(.signed(-half)); try signed.validate(.signed(half-1))
            XCTAssertThrowsError(try signed.validate(.signed(half)))
            XCTAssertThrowsError(try signed.validate(.signed(-half-1)))
            try unsigned.validate(.unsigned(maximum))
            XCTAssertThrowsError(try unsigned.validate(.unsigned(maximum+1)))
        }
        let decimal=try DMLColumnType("decimal(65,30)")
        try decimal.validate(.decimal("-12345678901234567890123456789012345.123456789012345678901234567890"))
        XCTAssertThrowsError(try decimal.validate(.decimal("1.1")))
        XCTAssertThrowsError(try DMLColumnType("decimal(4,4)").validate(.decimal("1.0000")))
        try DMLColumnType("decimal(4,4)").validate(.decimal("-0.9999"))
        XCTAssertThrowsError(try DMLColumnType("decimal(5,2) unsigned").validate(.decimal("-0.01")))
        for type in ["decimal(66,2)","decimal(5,6)","decimal(40,31)","float","json","vector(10)","enum('a')"] {
            XCTAssertThrowsError(try DMLColumnType(type))
        }
    }
    func testTemporalCanonicalizationDoesNotUseFloatingPointOrLocalTimezone() throws {
        XCTAssertEqual(try DMLColumnType("time(6)").canonicalTemporal("-838:59:58.000001"),"-838:59:58.000001")
        XCTAssertThrowsError(try DMLColumnType("time(6)").canonicalTemporal("838:59:59.000001"))
        XCTAssertEqual(try DMLColumnType("datetime(3)").canonicalTemporal("2024-02-29 12:34:56.123"),"2024-02-29 12:34:56.123000")
        XCTAssertEqual(try DMLColumnType("timestamp").canonicalTemporal("0000-00-00 00:00:00"),"0000-00-00 00:00:00.000000")
        XCTAssertEqual(try DMLColumnType("year").canonicalTemporal("0"),"0000")
        XCTAssertThrowsError(try DMLColumnType("time(2)").validate(.temporal("00:00:00.001000")))
        XCTAssertThrowsError(try DMLColumnType("year").validate(.temporal("1900")))
    }
    func testWirePrecisionAndSignednessMustMatchPreparedTable() throws {
        var wire=WireColumn(interpretation:.decimal,type:246,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:"d",metadata:Data([20,6]),isUnsigned:false)
        XCTAssertTrue(try DMLColumnType("decimal(20,6)").matches(wire))
        XCTAssertFalse(try DMLColumnType("decimal(20,5)").matches(wire))
        XCTAssertFalse(try DMLColumnType("decimal(20,6) unsigned").matches(wire))
        wire.isUnsigned=nil
        XCTAssertFalse(try DMLColumnType("decimal(20,6)").matches(wire))
        let timestamp=WireColumn(interpretation:.temporal,type:17,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([6]))
        XCTAssertTrue(try DMLColumnType("timestamp(6)").matches(timestamp))
        XCTAssertFalse(try DMLColumnType("datetime(6)").matches(timestamp))
        XCTAssertFalse(try DMLColumnType("timestamp(3)").matches(timestamp))
    }
    func testPreparedSchemaAttributesRoundTripAndOldSchemaStillLoads() throws {
        let old=Data(#"{"name":"id","type":"int","nullable":false}"#.utf8)
        var column=try JSONDecoder().decode(ApplyColumn.self,from:old)
        XCTAssertNil(column.extra); XCTAssertNil(column.defaultValue)
        column.extra="auto_increment"; try column.validate()
        column.defaultValue="7"
        XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self,from:JSONEncoder().encode(column)),column)
        column.extra="VIRTUAL GENERATED"; XCTAssertThrowsError(try column.validate())
        let decimal=ApplyColumn(name:"d",type:"decimal(10,2)",nullable:true,collation:nil)
        let time=ApplyColumn(name:"t",type:"time(6)",nullable:true,collation:nil)
        column.extra="auto_increment"; column.defaultValue=nil
        let table=ApplyTable(database:"poc",table:"test",columns:[column,decimal,time],primaryKey:"id")
        let plan=try DMLSQLPlan(table)
        XCTAssertTrue(plan.select.contains("CAST(`d` AS CHAR) AS `d`"))
        XCTAssertTrue(plan.select.contains("CAST(`t` AS CHAR) AS `t`"))
        XCTAssertTrue(plan.insert.contains("(`id`,`d`,`t`) VALUES (?,?,?)"))
    }
    func testTextBlobLimitsAndPrefixIndexes() throws {
        try DMLColumnType("tinyblob").validate(.binary(Data(repeating:255,count:255)))
        XCTAssertThrowsError(try DMLColumnType("tinyblob").validate(.binary(Data(repeating:255,count:256))))
        try DMLColumnType("mediumtext").validate(.text(String(repeating:"x",count:70000)))
        XCTAssertThrowsError(try DMLColumnType("text").validate(.text(String(repeating:"x",count:70000))))
        let table=ApplyTable(database:"poc",table:"test",columns:[ApplyColumn(name:"id",type:"int",nullable:false,collation:nil),ApplyColumn(name:"v",type:"text",nullable:true,collation:"utf8mb4_bin")],primaryKey:"id",secondaryIndexes:[ApplyIndex(name:"prefix",unique:false,parts:[ApplyIndexPart(column:"v",prefix:10)])])
        try table.validate()
    }
}
