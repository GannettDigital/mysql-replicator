import XCTest
import Foundation
@testable import ReplicatorApply

extension DDLTests {
    func testDatabaseDropJournalsSurvivingRelationshipWithoutRetiringChild() throws {
        #if os(Linux)
        let helpers=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helpers=ApplyTests()
        #endif
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=try StateStore(configuration:helpers.config(directory.appendingPathComponent("state").path))
        let parent=helpers.tables()[0]
        var child=ApplyTable(database:"outside",table:"child",columns:parent.columns,primaryKeyColumns:parent.primaryKeyColumns)
        child.foreignKeys=[ApplyForeignKey(name:"fk",database:child.database,table:child.table,columns:["id"],referencedDatabase:parent.database,referencedTable:parent.table,referencedColumns:["id"])]
        let group=ddlGroup(try helpers.groups()[0],sql:"DROP DATABASE poc")
        let plan=PreparedDDL(statement:.dropDatabase("poc",ifExists:false),before:nil,after:nil,sql:"DROP DATABASE poc",database:PreparedDatabaseDDL(name:"poc",before:DDLEncoding(characterSet:"utf8mb4",collation:"utf8mb4_bin"),after:nil,serverCollation:nil),additional:[SchemaTransition(before:parent,after:nil),SchemaTransition(before:child,after:child)])
        try store.begin(group);try store.ddlIntent(plan,event:group.events[1],coordinate:group.start)
        let db=store.directory.appendingPathComponent("state.sqlite")
        XCTAssertEqual(try helpers.sqlite(db,"SELECT json_array_length(transitions_json),status FROM ddl_details JOIN ddl_intents USING(gtid)"),[["2","PENDING"]])
        XCTAssertEqual(try helpers.sqlite(db,"SELECT SUM(current) FROM schemas"),[["2"]])
        try store.complete(group,rowCount:0,ddl:plan)
        XCTAssertEqual(try helpers.sqlite(db,"SELECT json_extract(schema_json,'$.database'),json_extract(schema_json,'$.foreignKeys[0].referencedDatabase') FROM schemas WHERE current=1"),[["outside","poc"]])
        XCTAssertEqual(try helpers.sqlite(db,"SELECT COUNT(*) FROM schemas"),[["2"]])
        XCTAssertEqual(try helpers.sqlite(db,"SELECT status FROM ddl_intents"),[["DONE"]])
        XCTAssertNoThrow(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child],filter:TableFilter(),missingParents:[parent.identity]))
        XCTAssertThrowsError(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child],filter:TableFilter()))
    }
}
