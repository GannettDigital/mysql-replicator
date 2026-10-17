import XCTest
import Foundation
@testable import ReplicatorApply

extension ForeignKeyTests {
    func testSupportingIndexOutcomesRejectUnrelatedSchemaChanges() throws {
        let before = try schema("c(id INT PRIMARY KEY,pid INT,n INT,KEY unrelated(n),CONSTRAINT fk FOREIGN KEY(pid) REFERENCES p(id))")
        let index = ApplyIndex(name:"wide",unique:false,parts:[.init(column:"pid",prefix:nil),.init(column:"n",prefix:nil)])
        let after = try IndexChange.add(index).applying(to:before)
        let optional = ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.add(index))])
        XCTAssertEqual(optional.map(\.name),["fk"])
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(after,expected:after,removable:optional))
        let removed = after.replacing(indexes:after.secondaryIndexes.filter { $0.name != "fk" })
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(removed,expected:after,removable:optional))
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(removed.replacing(indexes:[index]),expected:after,removable:optional))
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(before,expected:after,removable:optional))
        var changed = removed; changed.foreignKeys=[]
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(changed,expected:after,removable:optional))
        XCTAssertTrue(ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.rename("fk","fk")),.indexes(.add(index))]).isEmpty)
        let transition = SchemaTransition(before:before,after:after,removableSupportingIndexes:optional)
        let saved = try JSONDecoder().decode(SchemaTransition.self,from:JSONEncoder().encode(transition))
        XCTAssertEqual(saved.removableSupportingIndexes,optional)
        let legacy = try JSONDecoder().decode(SchemaTransition.self,from:Data("{}".utf8))
        XCTAssertNil(legacy.removableSupportingIndexes)
    }

    func testOnlyFullBTreeReplacementCanRemoveSupportingIndex() throws {
        let before = try schema("c(id INT PRIMARY KEY,pid VARCHAR(30),CONSTRAINT fk FOREIGN KEY(pid) REFERENCES p(pid))")
        for index in [ApplyIndex(name:"short",unique:false,parts:[.init(column:"pid",prefix:3)]),
                      ApplyIndex(name:"text",unique:false,parts:[.init(column:"pid",prefix:nil)],type:"FULLTEXT")] {
            let after = before.replacing(indexes:before.secondaryIndexes+[index])
            XCTAssertTrue(ForeignKeyGraph.removableIndexes(before:before,after:after,actions:[.indexes(.add(index))]).isEmpty)
        }
        let textOnly = before.replacing(indexes:[ApplyIndex(name:"text",unique:false,parts:[.init(column:"pid",prefix:nil)],type:"FULLTEXT")])
        XCTAssertFalse(textOnly.hasForeignKeyIndex(["pid"]))
    }

    func testColumnRenameUpdatesBothSidesOfSelfReferenceAndIncomingEdges() throws {
        let table = try schema("t(id INT PRIMARY KEY,pid INT,CONSTRAINT f FOREIGN KEY(pid) REFERENCES t(id))")
        let key = table.foreignKeys[0]
        let parent = key.renamingColumn(in:table.identity,from:"ID",to:"parent_key")
        XCTAssertEqual(parent.referencedColumns,["parent_key"])
        XCTAssertEqual(parent.columns,["pid"])
        let child = parent.renamingColumn(in:table.identity,from:"pid",to:"parent_id")
        XCTAssertEqual(child.columns,["parent_id"])
        XCTAssertEqual(child.referencedColumns,["parent_key"])
        XCTAssertEqual(child.name,"f")
        XCTAssertEqual(key.renamingColumn(in:SQLNameKey.table("poc","other"),from:"id",to:"other"),key)
    }
}
