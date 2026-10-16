import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

extension DDLTests {
    func testMultiDropAndCrossSchemaRenameParsingAndFilters() throws {
        let a=TableName(database:"poc",table:"a"),b=TableName(database:"otherdb",table:"b")
        XCTAssertEqual(try parse("DROP TABLE a,otherdb.b RESTRICT"),.dropMany([a,b],ifExists:false))
        XCTAssertEqual(try parse("DROP TABLE IF EXISTS a,otherdb.b CASCADE"),.dropMany([a,b],ifExists:true))
        XCTAssertEqual(try parse("DROP TABLE IF EXISTS a,a"),.dropMany([a,a],ifExists:true))
        XCTAssertEqual(try parse("RENAME TABLE a TO otherdb.b"),.rename(a,b))
        for sql in ["DROP TABLE a,","DROP TABLE a,b; DELETE FROM c","RENAME TABLE a TO a", "DROP TABLE "+(0...64).map { "t\($0)" }.joined(separator:",")] { XCTAssertThrowsError(try parse(sql),sql) }
        for sql in ["DROP TABLE a,otherdb.b", "RENAME TABLE a TO otherdb.b"] {
            let query=QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data())
            XCTAssertThrowsError(try TableFilter(["otherdb.%"]).ignores(query))
            XCTAssertTrue(try TableFilter(["poc.%","otherdb.%"]).ignores(query))
            XCTAssertFalse(try TableFilter(["excluded.%"]).ignores(query))
        }
        let failedSource=QueryControl(database:"poc",sql:Data("DROP TABLE a,missing,b".utf8),errorCode:1051,statusVariables:Data())
        XCTAssertThrowsError(try DDLStatement.parse(failedSource)) {
            XCTAssertTrue(String(describing:$0).contains("source query reported an error"))
        }
        var parser=try DDLParser(Data("DROP TABLE POC.A,OTHERDB.B".utf8),database:"poc")
        parser.lowerCaseTableNames=1
        XCTAssertEqual(try parser.parse(),.dropMany([a,b],ifExists:false))
    }
    func testMultiDropIntentKeepsEverySchemaUntilAtomicCheckpoint() throws {
        #if os(Linux)
        let f=ResumeTests(name:"fixtures",testClosure:{_ in})
        #else
        let f=ResumeTests()
        #endif
        let path=try f.directory(),config=try f.config(path.path),db=path.appendingPathComponent("state.sqlite")
        let original=f.helper.tables()[0]
        let names=[TableName(database:"poc",table:"a"),TableName(database:"otherdb",table:"b")]
        let tables=names.map { original.renamed(to:$0) },sql="DROP TABLE poc.a,otherdb.b"
        let group=ddlGroup(try f.helper.groups()[0],sql:sql)
        let plan=PreparedDDL(statement:.dropMany(names,ifExists:false),before:nil,after:nil,sql:sql,additional:tables.map { SchemaTransition(before:$0,after:nil) })
        do {
            let state=try StateStore(configuration:config)
            try state.bindTargetIdentity(f.target);try state.begin(group)
            try state.ddlIntent(plan,event:group.events[1],coordinate:group.start)
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT json_array_length(transitions_json) FROM ddl_details"),[["2"]])
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT status FROM ddl_intents"),[["PENDING"]])
            try f.write(path,"CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'fixture'); END")
            XCTAssertThrowsError(try state.complete(group,rowCount:0,ddl:plan))
            XCTAssertEqual(Set(state.currentSchemas.map(\.identity)),Set(tables.map(\.identity)))
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT SUM(current) FROM schemas"),[["2"]])
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT transactions_applied FROM state"),[["0"]])
            try f.write(path,"DROP TRIGGER fail_checkpoint")
            try state.complete(group,rowCount:0,ddl:plan);try state.stopped()
        }
        let reopened=try StateStore(configuration:config,initialize:false)
        XCTAssertTrue(reopened.currentSchemas.isEmpty)
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT COUNT(*),SUM(current) FROM schemas"),[["2","0"]])
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT target_sql,status FROM ddl_intents"),[[sql,"DONE"]])
    }
    func testCrossSchemaRenameRetainsTableEncodingAndForeignKeyNames() throws {
        let original=ApplyTable(database:"poc",table:"child",columns:[.init(name:"id",type:"int",nullable:false,collation:nil)],primaryKey:"id",defaultCharacterSet:"utf8mb4",defaultCollation:"utf8mb4_bin")
        var table=original
        table.foreignKeys=[ApplyForeignKey(name:"child_ibfk_1",database:"poc",table:"child",columns:["id"],referencedDatabase:"poc",referencedTable:"parent",referencedColumns:["id"])]
        let name=TableName(database:"otherdb",table:"moved")
        let renamed=table.renamed(to:name)
        XCTAssertEqual(renamed.defaultCollation,"utf8mb4_bin")
        XCTAssertEqual(renamed.foreignKeys[0].name,"moved_ibfk_1")
        XCTAssertEqual(renamed.foreignKeys[0].database,"otherdb")
        XCTAssertEqual(renamed.foreignKeys[0].referencedDatabase,"poc")
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(renamed)),renamed)
    }
}
