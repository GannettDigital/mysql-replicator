import XCTest
import ReplicatorConfiguration
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class SchemaChangeTests: XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    var table:ApplyTable {ApplyTable(database:"poc",table:"t",columns:[
        ApplyColumn(name:"id",type:"int",nullable:false,collation:nil),
        ApplyColumn(name:"name",type:"varchar(40)",nullable:false,collation:"utf8mb4_bin",characterSet:"utf8mb4")],primaryKey:"id",defaultCharacterSet:"utf8mb4",defaultCollation:"utf8mb4_unicode_ci")}
    func testExactDemoModifyAndPlacementAreFullReplacementDefinitions() throws {
        guard case .modify(let name,let column,let placement)=try parse("ALTER TABLE demo.explicit_default_engine MODIFY COLUMN name VARCHAR(120);") else {return XCTFail("not MODIFY")}
        XCTAssertEqual(name.database,"demo");XCTAssertEqual(column.type,"varchar(120)")
        XCTAssertTrue(column.nullable);XCTAssertNil(column.collation);XCTAssertNil(placement)
        let replacement=ApplyColumn(name:"name",type:"varchar(120)",nullable:true,collation:"utf8mb4_unicode_ci",characterSet:"utf8mb4")
        let result=try table.modifying(replacement,placement:.first)
        XCTAssertEqual(result.columns.map(\.name),["name","id"])
        XCTAssertTrue(result.columns[0].nullable);XCTAssertEqual(result.columns[0].collation,"utf8mb4_unicode_ci")
        XCTAssertThrowsError(try table.modifying(replacement,placement:.after("name")))
        XCTAssertThrowsError(try table.modifying(ApplyColumn(name:"name",type:"int",nullable:true,collation:nil),placement:nil))
    }
    func testIndexAliasesReplacementAndQuotedIdentifiers() throws {
        let key=ApplyIndex(name:"ix",unique:true,parts:[ApplyIndexPart(column:"name",prefix:8),ApplyIndexPart(column:"id",prefix:nil)])
        let expected=DDLStatement.indexes(TableName(database:"poc",table:"t"),.add(key))
        for sql in ["CREATE UNIQUE INDEX ix USING BTREE ON t(name(8) ASC,id)","CREATE UNIQUE INDEX ix ON t(name(8),id) USING BTREE","ALTER TABLE t ADD UNIQUE KEY ix (name(8),id)","ALTER TABLE t ADD UNIQUE INDEX ix USING BTREE(name(8),id)"] {XCTAssertEqual(try parse(sql),expected,sql)}
        XCTAssertEqual(try parse("ALTER TABLE t DROP INDEX old, ADD UNIQUE INDEX ix(name(8),id)"),.indexes(TableName(database:"poc",table:"t"),.replace("old",key)))
        XCTAssertEqual(try parse("DROP INDEX `odd``name` ON t"),.indexes(TableName(database:"poc",table:"t"),.drop("odd`name")))
        XCTAssertEqual(try parse("ALTER TABLE t RENAME KEY ix TO other"),.indexes(TableName(database:"poc",table:"t"),.rename("ix","other")))
    }
    func testUnsupportedOptionsCannotFallThroughToSQL() throws {
        for sql in ["CREATE INDEX ix ON t(name DESC)","CREATE FULLTEXT INDEX ix ON t(name)","CREATE INDEX ix ON t((id+1))","ALTER TABLE t MODIFY name VARCHAR(120) ALGORITHM=COPY","CREATE INDEX ix ON t(name) INVISIBLE","CREATE INDEX ix USING HASH ON t(name)","CREATE INDEX ix ON t(name(0))"] {XCTAssertThrowsError(try parse(sql),sql)}
    }
    func testIndexModelRejectsUnsupportedShapeAndPreservesPrimaryRowIdentity() throws {
        let key=ApplyIndex(name:"ix",unique:false,parts:[ApplyIndexPart(column:"name",prefix:10)])
        let indexed=try IndexChange.add(key).applying(to:table)
        XCTAssertEqual(indexed.primaryKey,"id");XCTAssertEqual(indexed.keyIndex,0)
        XCTAssertThrowsError(try IndexChange.add(key).applying(to:indexed))
        XCTAssertThrowsError(try IndexChange.drop("PRIMARY").applying(to:indexed))
        XCTAssertThrowsError(try IndexChange.rename("ix","PRIMARY").applying(to:indexed))
        XCTAssertThrowsError(try IndexChange.add(ApplyIndex(name:"bad",unique:false,parts:[ApplyIndexPart(column:"missing",prefix:nil)])).applying(to:table))
        XCTAssertThrowsError(try indexed.modifying(ApplyColumn(name:"name",type:"varchar(5)",nullable:true,collation:"utf8mb4_bin"),placement:nil))
        let renamed=try IndexChange.rename("ix","new").applying(to:indexed)
        XCTAssertEqual(renamed.secondaryIndexes[0].parts,key.parts)
        let replaced=try IndexChange.replace("new",ApplyIndex(name:"new",unique:true,parts:[ApplyIndexPart(column:"name",prefix:nil)])).applying(to:renamed)
        XCTAssertTrue(replaced.secondaryIndexes[0].unique)
        XCTAssertEqual(try IndexChange.drop("new").applying(to:replaced),table)
    }
    func testOldSchemaDecodesWithoutIndexesAndNewSchemaRoundTrips() throws {
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(table)) as! [String:Any]
        json.removeValue(forKey:"secondaryIndexes")
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONSerialization.data(withJSONObject:json)),table)
        let indexed=try IndexChange.add(ApplyIndex(name:"ix",unique:true,parts:[ApplyIndexPart(column:"name",prefix:nil)])).applying(to:table)
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(indexed)),indexed)
    }
    func testCleanFormatFourUpgradeIsAtomicAndBlockedMigrationIsRefused() throws {
        #if os(Linux)
        let f=ResumeTests(name:"fixtures",testClosure:{_ in})
        #else
        let f=ResumeTests()
        #endif
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let path=parent.appendingPathComponent("state"),c=try f.config(path.path)
        do {
            let state=try StateStore(configuration:c)
            try state.bindTargetIdentity(f.target);try state.running()
            try f.apply(f.helper.groups()[0],to:state);try state.stopped()
        }
        try f.write(path,"DROP TABLE ddl_skips; UPDATE schemas SET schema_json=json_remove(schema_json,'$.secondaryIndexes'); PRAGMA user_version=4")
        let db=path.appendingPathComponent("state.sqlite")
        let before=try f.helper.sqlite(db,"SELECT * FROM state")
        let history=try f.helper.sqlite(db,"SELECT * FROM schemas")
        let groups=try f.helper.sqlite(db,"SELECT * FROM groups")
        let intents=try f.helper.sqlite(db,"SELECT * FROM row_intents")
        do {let state=try StateStore(configuration:c,initialize:false);XCTAssertEqual(state.transactions,1)}
        XCTAssertEqual(try f.helper.sqlite(db,"PRAGMA user_version"),[["7"]])
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT * FROM state"),before)
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT * FROM schemas"),history)
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT * FROM groups"),groups)
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT * FROM row_intents"),intents)
        try f.write(path,"PRAGMA user_version=4; UPDATE state SET lifecycle='BLOCKED'")
        XCTAssertThrowsError(try StateStore(configuration:c,initialize:false))
        XCTAssertEqual(try f.helper.sqlite(db,"PRAGMA user_version"),[["4"]])
    }
    func testDDLDeadlineIsIndependentBoundedAndDefaultsToFiveMinutes() throws {
        #if os(Linux)
        let f=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let f=ApplyTests()
        #endif
        XCTAssertEqual(try f.config().ddlDeadline,300)
        // Use a valid fixture so an unrelated placeholder cannot satisfy rejection.
        let valid=try f.config()
        let template=try String(contentsOf:f.root.appendingPathComponent("examples/apply.example.yaml"),encoding:.utf8)
            .replacingOccurrences(of:"REPLACE_SOURCE_UUID",with:valid.source.sourceUUID)
            .replacingOccurrences(of:"REPLACE_SNAPSHOT_GTID_SET",with:"\"\"")
        for seconds in [1,300,86400] {
            let text=template.replacingOccurrences(of:"ddlTimeoutSeconds: 300",with:"ddlTimeoutSeconds: \(seconds)")
            let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
            XCTAssertEqual(config.ddlDeadline,seconds);try config.validate()
        }
        for seconds in [0,86401] {
            let text=template.replacingOccurrences(of:"ddlTimeoutSeconds: 300",with:"ddlTimeoutSeconds: \(seconds)")
            let config=try ConfigurationFile.decode(ApplyConfiguration.self,from:Data(text.utf8))
            XCTAssertThrowsError(try config.validate()) { XCTAssertTrue(String(describing:$0).contains("DDL timeout")) }
        }
    }
}
