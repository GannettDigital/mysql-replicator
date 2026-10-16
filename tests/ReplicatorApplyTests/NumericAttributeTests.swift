import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class NumericAttributeTests: XCTestCase {
    func testLegacyFloatingAutoIncrementRetainsExplicitValues() throws {
        for type in ["FLOAT","DOUBLE","FLOAT(10,2)","DOUBLE UNSIGNED"] {
            var parser=try DDLParser(Data("CREATE TABLE t(id \(type) AUTO_INCREMENT PRIMARY KEY,v INT)".utf8),database:"poc")
            guard case .create(let table,_) = try parser.parse() else { return XCTFail("not CREATE") }
            try table.validate()
            XCTAssertEqual(table.columns[0].extra,"auto_increment")
            let sql=try DMLSQLPlan(table).insert
            XCTAssertTrue(sql.hasPrefix("INSERT INTO `poc`.`t` (`id`,`v`) VALUES ("))
            XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        }
        XCTAssertThrowsError(try ApplyColumn(name:"id",type:"float",nullable:true,collation:nil,extra:"auto_increment").validate())
        XCTAssertThrowsError(try ApplyColumn(name:"id",type:"decimal(10,2)",nullable:false,collation:nil,extra:"auto_increment").validate())
    }
    func testDDLRetainsZerofillWidthsAndImplicitUnsigned() throws {
        var parser=try DDLParser(Data("CREATE TABLE z(id INT ZEROFILL PRIMARY KEY,a TINYINT(6) ZEROFILL DEFAULT 7,b DECIMAL(8,2) ZEROFILL DEFAULT 1.25,c FLOAT ZEROFILL DEFAULT 1.25,d DOUBLE(10,2) ZEROFILL DEFAULT 1.235,e INT(0) ZEROFILL,f BIGINT ZEROFILL,y YEAR ZEROFILL,n INT SIGNED)".utf8),database:"poc")
        guard case .create(let table,_) = try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertThrowsError(try table.validate()) // DECIMAL default needs native resolution.
        XCTAssertEqual(table.columns.map(\.type),["int(10) unsigned zerofill","tinyint(6) unsigned zerofill","decimal(8,2) unsigned zerofill","float unsigned zerofill","double(10,2) unsigned zerofill","int(10) unsigned zerofill","bigint(20) unsigned zerofill","year","int"])
        for mysql84 in [false,true] {
            for (index,native) in [(1,"000007"),(2,"000001.25"),(3,"000000001.25"),(4,"0000001.24")] {
                XCTAssertEqual(try TargetColumnMetadata.defaultValue(native,type:table.columns[index].type,mysql84:mysql84),table.columns[index].defaultValue)
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
    }
    func testDisplayWidthDoesNotLimitStoredIntegerRange() throws {
        let type=try DMLColumnType("tinyint(1) unsigned zerofill")
        XCTAssertTrue(type.unsigned); XCTAssertTrue(type.zerofill)
        try type.validate(.unsigned(255))
        XCTAssertThrowsError(try type.validate(.unsigned(256)))
        XCTAssertThrowsError(try type.validate(.signed(-1)))
        XCTAssertTrue(type.matches(WireColumn(interpretation:.unsigned,type:1,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,isUnsigned:true)))
        XCTAssertThrowsError(try DMLColumnType("int(256) unsigned zerofill"))
        XCTAssertThrowsError(try DMLColumnType("varchar(8) zerofill"))
        XCTAssertEqual(try normalizedDefault("000001.25",type:DMLColumnType("decimal(8,2) unsigned zerofill")),"1.25")
    }
}
