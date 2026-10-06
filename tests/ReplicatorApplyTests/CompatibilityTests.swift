import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class CompatibilityTests: XCTestCase {
    func testOrderedChoiceLabelsAreParsedWithoutSQLReinterpretation() throws {
        let type = try DMLColumnType(#"enum('','one','it''s','x,y','a\\b','\0\n\r','🙂')"#)
        XCTAssertEqual(type.labels,["","one","it's","x,y","a\\b","\0\n\r","🙂"].map { Data($0.utf8) })
        XCTAssertThrowsError(try type.validate(.unsigned(0))); try type.validate(.unsigned(1)); try type.validate(.unsigned(7))
        XCTAssertThrowsError(try type.validate(.unsigned(8)))
        XCTAssertThrowsError(try type.validate(.text("one")))
        XCTAssertThrowsError(try DMLColumnType("enum('a',)"))
        XCTAssertThrowsError(try DMLColumnType("enum('a') unsigned"))
        let set = try DMLColumnType("set('a','b')")
        try set.validate(.unsigned(3)); XCTAssertThrowsError(try set.validate(.unsigned(4)))
        let full = try DMLColumnType("set("+(0..<64).map { "'s\($0)'" }.joined(separator:",")+")")
        try full.validate(.unsigned(.max))
    }
    func testChoiceMetadataMustMatchLabelsAndPackingWidth() throws {
        let column=ApplyColumn(name:"e",type:"enum('a','b')",nullable:false,collation:"utf8mb4_bin",characterSet:"utf8mb4")
        let plan=try DMLTablePlan(ApplyTable(database:"poc",table:"test",columns:[column],primaryKey:"e"))
        var wire=WireColumn(interpretation:.unsigned,type:247,maximumBytes:0,nullable:false,collation:46,primaryKey:true,name:"e",metadata:Data([247,1]),labels:[Data("a".utf8),Data("b".utf8)])
        try plan.validate(wire:[wire])
        wire.labels?.reverse(); XCTAssertThrowsError(try plan.validate(wire:[wire]))
        wire.labels=nil; XCTAssertThrowsError(try plan.validate(wire:[wire]))
        wire.labels=[Data("a".utf8),Data("b".utf8)]; wire.metadata=Data([247,2])
        XCTAssertThrowsError(try plan.validate(wire:[wire]))
    }
    func testFixedWidthsAndCharacterPrimaryKey() throws {
        try DMLColumnType("char(255)").validate(.text(String(repeating:"🙂",count:255)))
        XCTAssertThrowsError(try DMLColumnType("char(1)").validate(.text("ab")))
        try DMLColumnType("binary(3)").validate(.binary(Data([1,0,0])))
        XCTAssertThrowsError(try DMLColumnType("binary(3)").validate(.binary(Data([1]))))
        try DMLColumnType("binary(0)").validate(.binary(Data()))
        XCTAssertThrowsError(try DMLColumnType("char(256)"))
    }
    func testCompositeKeyOrderingSQLAndSchemaPersistence() throws {
        let table=ApplyTable(database:"poc",table:"reports",columns:[
            ApplyColumn(name:"id",type:"int",nullable:false,collation:nil),
            ApplyColumn(name:"report_date",type:"date",nullable:false,collation:nil),
            ApplyColumn(name:"v",type:"int",nullable:true,collation:nil)],primaryKeyColumns:["report_date","id"])
        try table.validate()
        let plan=try DMLSQLPlan(table)
        XCTAssertEqual(plan.keyIndexes,[1,0])
        XCTAssertTrue(plan.select.hasSuffix("WHERE `report_date`=? AND `id`=?"))
        XCTAssertTrue(plan.update.hasSuffix("WHERE `report_date`=? AND `id`=?"))
        XCTAssertTrue(plan.delete.hasSuffix("WHERE `report_date`=? AND `id`=?"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        XCTAssertEqual(table.replacing(indexes:[]).primaryKeyColumns,["report_date","id"])
        let single=ApplyTable(database:"poc",table:"reports",columns:table.columns,primaryKey:"id")
        let data=try JSONEncoder().encode(single)
        XCTAssertTrue(String(decoding:data,as:UTF8.self).contains("\"primaryKey\":\"id\""))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:data),single)
        for names in [[],["id","id"],["missing"],["v"]] {
            XCTAssertThrowsError(try ApplyTable(database:"poc",table:"reports",columns:table.columns,primaryKeyColumns:names).validate())
        }
    }
    func testCompositePrimaryKeyDDLAndNonleadingKeyModification() throws {
        let query=QueryControl(database:"poc",sql:Data("CREATE TABLE reports(id INT, report_date DATE, value CHAR(9), PRIMARY KEY(report_date,id))".utf8),errorCode:0,statusVariables:Data())
        guard case .create(let table,_)=try DDLStatement.parse(query) else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.primaryKeyColumns,["report_date","id"])
        XCTAssertFalse(table.columns[0].nullable); XCTAssertFalse(table.columns[1].nullable)
        let ready=ApplyTable(database:"poc",table:"reports",columns:Array(table.columns.prefix(2)),primaryKeyColumns:table.primaryKeyColumns)
        let changed=try ready.modifying(ApplyColumn(name:"id",type:"bigint",nullable:true,collation:nil),placement:.last)
        XCTAssertFalse(changed.columns.last!.nullable)
        XCTAssertEqual(changed.primaryKeyColumns,["report_date","id"])
    }
}
