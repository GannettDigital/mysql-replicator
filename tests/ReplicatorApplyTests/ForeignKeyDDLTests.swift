import XCTest
import Foundation
@testable import ReplicatorApply

extension ForeignKeyTests {
    func testSupportingIndexOutcomesRejectUnrelatedSchemaChanges() throws {
        let before = try schema("c(id INT PRIMARY KEY,pid INT,n INT,KEY unrelated(n),CONSTRAINT fk FOREIGN KEY(pid) REFERENCES p(id))")
        let index = ApplyIndex(name:"wide",unique:false,parts:[.init(column:"pid",prefix:nil),.init(column:"n",prefix:nil)])
        let after = try IndexChange.add(index).applying(to:before)
        let optional = try ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.add(index))])
        XCTAssertEqual(optional.map(\.name),["fk"])
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(after,expected:after,removable:optional))
        let removed = after.replacing(indexes:after.secondaryIndexes.filter { $0.name != "fk" })
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(removed,expected:after,removable:optional))
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(removed.replacing(indexes:[index]),expected:after,removable:optional))
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(before,expected:after,removable:optional))
        var changed = removed; changed.foreignKeys=[]
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(changed,expected:after,removable:optional))
        XCTAssertTrue(try ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.rename("fk","fk")),.indexes(.add(index))]).isEmpty)
        let transition = SchemaTransition(before:before,after:after,removableSupportingIndexes:optional)
        let saved = try JSONDecoder().decode(SchemaTransition.self,from:JSONEncoder().encode(transition))
        XCTAssertEqual(saved.removableSupportingIndexes,optional)
        let legacy = try JSONDecoder().decode(SchemaTransition.self,from:Data("{}".utf8))
        XCTAssertNil(legacy.removableSupportingIndexes)
    }

    func testSupportingIndexRemovalUsesFinalColumnNames() throws {
        let before=try schema("c(id INT PRIMARY KEY,a INT,b INT,CONSTRAINT fk FOREIGN KEY(a) REFERENCES p(id))")
        let actions:[AlterAction]=[
            .modify("a",.init(name:"b",type:"int",nullable:true,collation:nil),nil),
            .modify("b",.init(name:"a",type:"int",nullable:true,collation:nil),nil),
            .indexes(.add(.init(name:"wide",unique:false,parts:[.init(column:"b",prefix:nil),.init(column:"a",prefix:nil)])))
        ]
        var after=try AlterColumnLayout.applying(to:before,actions:actions)
        if case .indexes(let change)=actions[2] {after=try change.applying(to:after)}
        let optional=try ForeignKeyGraph.removableIndexes(before:before,after:after,actions:actions)
        XCTAssertEqual(optional.map(\.name),["fk"])
        XCTAssertEqual(optional[0].parts[0].column,"b")
        let observed=after.replacing(indexes:after.secondaryIndexes.filter{$0.name != "fk"})
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(observed,expected:after,removable:optional))
    }

    func testOnlyFullBTreeReplacementCanRemoveSupportingIndex() throws {
        let before = try schema("c(id INT PRIMARY KEY,pid VARCHAR(30),CONSTRAINT fk FOREIGN KEY(pid) REFERENCES p(pid))")
        for index in [ApplyIndex(name:"short",unique:false,parts:[.init(column:"pid",prefix:3)]),
                      ApplyIndex(name:"text",unique:false,parts:[.init(column:"pid",prefix:nil)],type:"FULLTEXT")] {
            let after = before.replacing(indexes:before.secondaryIndexes+[index])
            XCTAssertTrue(try ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.add(index))]).isEmpty)
        }
        let textOnly = before.replacing(indexes:[ApplyIndex(name:"text",unique:false,parts:[.init(column:"pid",prefix:nil)],type:"FULLTEXT")])
        XCTAssertFalse(textOnly.hasForeignKeyIndex(["pid"]))
    }

    func testColumnRenameUpdatesBothSidesOfSelfReferenceAndIncomingEdges() throws {
        let table = try schema("t(id INT PRIMARY KEY,pid INT,CONSTRAINT f FOREIGN KEY(pid) REFERENCES t(id))")
        let key = table.foreignKeys[0]
        func rename(_ old:String,_ new:String) throws -> ColumnNameChanges {
            try ColumnNameChanges([.modify(old,.init(name:new,type:"int",nullable:true,collation:nil),nil)])
        }
        let parent = key.renamingColumns(in:table.identity,using:try rename("ID","parent_key"))
        XCTAssertEqual(parent.referencedColumns,["parent_key"])
        XCTAssertEqual(parent.columns,["pid"])
        let child = parent.renamingColumns(in:table.identity,using:try rename("pid","parent_id"))
        XCTAssertEqual(child.columns,["parent_id"])
        XCTAssertEqual(child.referencedColumns,["parent_key"])
        XCTAssertEqual(child.name,"f")
        XCTAssertEqual(key.renamingColumns(in:SQLNameKey.table("poc","other"),using:try rename("id","other")),key)
    }
}
