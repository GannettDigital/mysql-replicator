import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class RowIdentityTests: XCTestCase {
    func table() -> ApplyTable {
        ApplyTable(database:"poc",table:"t",columns:[.init(name:"payload",type:"int",nullable:true),.init(name:"day",type:"date",nullable:false),.init(name:"id",type:"int",nullable:false)],primaryKeyColumns:[],secondaryIndexes:[.init(name:"z_id",unique:true,parts:[.init(column:"id",prefix:nil)]),.init(name:"a_day_id",unique:true,parts:[.init(column:"day",prefix:nil),.init(column:"id",prefix:nil)])])
    }
    func testSelectionSQLAndSavedIdentity() throws {
        let t=table();try t.validate()
        XCTAssertEqual(t.primaryKeyColumns,[])
        XCTAssertEqual(t.rowIdentity,.init(kind:.unique,index:"a_day_id",columns:["day","id"]))
        XCTAssertEqual(t.keyIndexes,[1,2])
        let sql=try DMLSQLPlan(t)
        XCTAssertTrue(sql.update.hasSuffix("WHERE `day`=? AND `id`=?"))
        XCTAssertTrue(sql.delete.hasSuffix("WHERE `day`=? AND `id`=?"))
        let bytes=try JSONEncoder().encode(t)
        var restored=try JSONDecoder().decode(ApplyTable.self,from:bytes)
        XCTAssertEqual(restored,t)
        restored.secondaryIndexes.reverse()
        XCTAssertEqual(restored.rowIdentity,t.rowIdentity)
        restored.secondaryIndexes.removeAll{$0.name == "a_day_id"}
        XCTAssertThrowsError(try restored.validate())
        // A new DDL schema can choose another key; an existing saved schema cannot.
        let next=try IndexChange.drop("a_day_id").applying(to:t)
        try next.validate()
        XCTAssertEqual(next.rowIdentity?.index,"z_id")
        let primary=t.replacing(primaryKey:["id"])
        XCTAssertEqual(primary.rowIdentity,.init(kind:.primary,index:"PRIMARY",columns:["id"]))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(primary),as:UTF8.self).contains("rowIdentity"))
    }
    func testIneligibleKeysDoNotProduceAnEmptyWhereClause() throws {
        let t=table()
        let indexes:[ApplyIndex]=[
            .init(name:"nullable",unique:true,parts:[.init(column:"payload",prefix:nil)]),
            .init(name:"ordinary",unique:false,parts:[.init(column:"id",prefix:nil)]),
            .init(name:"prefix",unique:true,parts:[.init(column:"id",prefix:1)]),
            .init(name:"expression",unique:true,parts:[.init(column:nil,prefix:nil,expression:"(`id` + 1)")])
        ]
        for index in indexes {
            let invalid=t.replacing(indexes:[index])
            XCTAssertEqual(invalid.rowIdentity?.kind,.fullRow)
            XCTAssertNoThrow(try DMLSQLPlan(invalid))
        }
        let generated=t.replacing(columns:[t.columns[0],t.columns[1],.init(name:"id",type:"int",nullable:false,extra:"STORED GENERATED",generationExpression:"1")],indexes:[t.secondaryIndexes[0]])
        XCTAssertEqual(generated.rowIdentity?.columns,["payload","day"])
    }
    func testPartialOptionalMetadataStillChecksPresentKeyFlags() throws {
        let table=ApplyTable(database:"poc",table:"t",columns:[.init(name:"id",type:"int",nullable:false),.init(name:"payload",type:"int",nullable:true)],primaryKey:"id",secondaryIndexes:[.init(name:"by_id",unique:true,parts:[.init(column:"id",prefix:nil)])])
        let unnamed=WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil)
        for schema in [table,table.replacing(primaryKey:[])] {
            for flag in [false,true] {
                let wire=[WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:flag,name:"id"),unnamed]
                if flag { XCTAssertNoThrow(try DMLTablePlan(schema).validate(wire:wire)) }
                else { XCTAssertThrowsError(try DMLTablePlan(schema).validate(wire:wire)) }
            }
        }
    }
    func testFullMetadataCanUseAnotherEligibleUniqueKey() throws {
        let table=table()
        let wire=[WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:"payload"),WireColumn(interpretation:.temporal,type:10,maximumBytes:0,nullable:false,collation:0,primaryKey:false,name:"day"),WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:true,name:"id")]
        XCTAssertNoThrow(try DMLTablePlan(table).validate(wire:wire))
        XCTAssertEqual(table.rowIdentity?.index,"a_day_id")
    }
}
