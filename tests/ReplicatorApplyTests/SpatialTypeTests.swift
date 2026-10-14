import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class SpatialTypeTests:XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testSpatialSubtypeMetadataAndBinaryValues() throws {
        for (code,name) in DMLColumnType.spatialTypes.enumerated() {
            let type=try DMLColumnType(name)
            XCTAssertEqual(type.interpretation,.binary)
            var wire=WireColumn(interpretation:.binary,type:255,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([4]))
            XCTAssertTrue(type.matches(wire)) // MySQL 5.7/MINIMAL has no subtype list.
            wire.geometryType=UInt32(code); XCTAssertTrue(type.matches(wire))
            wire.geometryType=UInt32((code+1)%8); XCTAssertFalse(type.matches(wire))
            try type.validate(.binary(Data([0,0,0,0,1,7,0,0,0,0,0,0,0])))
            XCTAssertThrowsError(try type.validate(.text("POINT(1 2)")))
            XCTAssertThrowsError(try DMLColumnType(name+" unsigned"))
            XCTAssertThrowsError(try DMLColumnType(name+"(1)"))
        }
    }
    func testSpatialDDLIndexesAndSavedSchemas() throws {
        guard case .create(let table,_) = try parse("CREATE TABLE geo(id INT PRIMARY KEY,g GEOMETRY NOT NULL,c GEOMCOLLECTION,SPATIAL INDEX gx(g))") else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns[2].type,"geometrycollection")
        XCTAssertEqual(table.secondaryIndexes.first?.type,"SPATIAL")
        try table.validate()
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        let added=try parse("ALTER TABLE geo ADD SPATIAL INDEX cx(g)")
        let created=try parse("CREATE SPATIAL INDEX cx ON geo(g)")
        XCTAssertEqual(added,created)
        guard case .indexes(_,let change)=created else { return XCTFail("not INDEX") }
        let changed=try change.applying(to:table)
        XCTAssertEqual(changed.secondaryIndexes.count,2)
        let plan=try DMLSQLPlan(table)
        XCTAssertTrue(plan.select.contains("`g`"))
        XCTAssertFalse(plan.select.contains("ST_AsText"))
        for sql in ["CREATE TABLE t(g POINT PRIMARY KEY)",
                    "CREATE TABLE t(id INT PRIMARY KEY,g POINT,SPATIAL INDEX(g))",
                    "CREATE TABLE t(id INT PRIMARY KEY,g POINT NOT NULL,SPATIAL INDEX(g(4)))",
                    "CREATE TABLE t(id INT PRIMARY KEY,g INT NOT NULL,SPATIAL INDEX(g))"] {
            XCTAssertThrowsError(try { guard case .create(let t,_)=try parse(sql) else { return }; try t.validate() }(),sql)
        }
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY,g POINT SRID 4326)"))
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY,g POINT DEFAULT 'POINT(1 2)')"))
    }
}
