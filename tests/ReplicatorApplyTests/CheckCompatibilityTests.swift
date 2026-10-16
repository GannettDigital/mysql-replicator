import Foundation
import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class CheckCompatibilityTests:XCTestCase {
    func rewrite(_ sql:String,profile:ReplicationProfile = .mysql57To84InnoDB) throws -> (DDLStatement,String) {
        let raw=Data(sql.utf8)
        var parser=try DDLParser(raw,database:"poc")
        parser.engine=profile.targetContract.engine
        parser.targetVersion=profile.targetContract.versionPrefix
        parser.nativeRules=NativeReplicationRules(profile:profile)
        let statement=try parser.parse()
        return (statement,statement.ignoredChecksOnly ? "" : parser.translatedSQL(raw))
    }
    func testNativeVersionBoundaries() {
        for version:UInt32 in [0,50700,50744,80015,999999] {
            XCTAssertEqual(NativeReplicationRules(sourceVersion:version,targetVersion:80400).checkConstraints,.discard)
        }
        XCTAssertEqual(NativeReplicationRules(sourceVersion:80016,targetVersion:80400).checkConstraints,.preserve)
        XCTAssertEqual(NativeReplicationRules(sourceVersion:80400,targetVersion:50744).checkConstraints,.targetUnsupported)
        for profile in ReplicationProfile.allCases {
            XCTAssertEqual(NativeReplicationRules(profile:profile).checkConstraints,profile == .mysql84To57MyISAM ? .targetUnsupported : .discard)
        }
    }
    func testCreateElisionAtEachListPositionAndInline() throws {
        for (sql,expected) in [
            ("CREATE TABLE t(CHECK(id>0), id INT PRIMARY KEY)","CREATE TABLE t(id INT PRIMARY KEY)"),
            ("CREATE TABLE t(id INT PRIMARY KEY, CHECK(id>0), CHECK(id<0))","CREATE TABLE t(id INT PRIMARY KEY)"),
            ("CREATE TABLE t(CHECK(id>0), CONSTRAINT c CHECK(id<0), id INT PRIMARY KEY, CHECK(id=0), v INT CHECK(v>0))","CREATE TABLE t(id INT PRIMARY KEY, v INT )"),
            ("CREATE TABLE t(id INT PRIMARY KEY, CONSTRAINT c CHECK(unknown_fn(id,'),;')>0), v VARCHAR(30) DEFAULT 'CHECK(x)' COMMENT 'CHECK kept')","CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(30) DEFAULT 'CHECK(x)' COMMENT 'CHECK kept')")
        ] {
            XCTAssertEqual(try rewrite(sql).1,expected)
            XCTAssertNoThrow(try DDLStatement.parse(.init(database:"poc",sql:Data(expected.utf8),errorCode:0,statusVariables:Data()),profile:.mysql57To84InnoDB))
        }
    }
    func testAlterNoOpAndMixedActions() throws {
        let (statement,sql)=try rewrite("ALTER TABLE t ADD CONSTRAINT c CHECK(id>0), ADD CHECK(id<0), ALGORITHM=COPY")
        XCTAssertTrue(statement.ignoredChecksOnly);XCTAssertEqual(sql,"")
        XCTAssertEqual(try rewrite("ALTER TABLE t ADD CHECK(id>0), ADD v INT CHECK(v<0), ADD CHECK(id<0)").1,"ALTER TABLE t ADD v INT ")
        XCTAssertEqual(try rewrite("ALTER TABLE t ADD v INT, ADD CHECK(v>0), ADD w INT").1,"ALTER TABLE t ADD v INT, ADD w INT")
        XCTAssertEqual(try rewrite("ALTER TABLE t MODIFY v INT, ADD CHECK(v<0)").1,"ALTER TABLE t MODIFY v INT")
        for bad in ["ALTER TABLE t ADD CHECK()", "ALTER TABLE t ADD CHECK(1); DROP TABLE t", "CREATE TABLE t(id INT PRIMARY KEY CHECK (1; DROP TABLE t))", "ALTER TABLE t ADD CHECK(id>0) ENFORCED"] {
            XCTAssertThrowsError(try rewrite(bad),bad)
        }
    }
    func testNewSourceChecksAreNeverSilentlyDropped() {
        for sql in ["CREATE TABLE t(id INT PRIMARY KEY CHECK(id>0))", "CREATE TABLE t(id INT PRIMARY KEY,CONSTRAINT c CHECK(id>0))", "ALTER TABLE t ADD CHECK(id>0)"] {
            XCTAssertThrowsError(try rewrite(sql,profile:.mysql84To57MyISAM)) { error in
                XCTAssertTrue(String(describing:error).contains("cannot preserve CHECK constraints"))
            }
        }
    }
    func testEncodedLiteralBytesSurviveCheckRemoval() throws {
        let raw=Data("CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(20) DEFAULT '".utf8)+Data([0xe9])+Data("' CHECK(id>0))".utf8)
        let tokens=try DDLTokens.lex(raw,characterSet:"latin1") { bytes,identifier in
            .init(text:String(data:bytes,encoding:.isoLatin1)!,bytes:identifier ? nil : bytes)
        }
        var parser=try DDLParser(query:.init(database:"poc",sql:raw,errorCode:0,statusVariables:Data()),tokens:tokens)
        parser.nativeRules=NativeReplicationRules(profile:.mysql57To57MyISAM)
        _ = try parser.parse()
        let expected=Data("CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(20) DEFAULT '".utf8)+Data([0xe9])+Data("' )".utf8)
        XCTAssertEqual(parser.translatedBytes(raw),expected)
    }
    func testByteRangesComposeWithCollationTranslation() throws {
        let raw=Data("CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(30) DEFAULT 'café CHECK(x)' CHECK(id>0), CONSTRAINT c CHECK(v<>'x')) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_0900_ai_ci".utf8)
        var parser=try DDLParser(raw,database:"poc")
        parser.nativeRules=NativeReplicationRules(profile:.mysql57To57MyISAM)
        parser.compatibility=CompatibilityPolicy(collations:["utf8mb4_0900_ai_ci":"utf8mb4_bin"])
        _ = try parser.parse()
        XCTAssertEqual(parser.translatedSQL(raw),"CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(30) DEFAULT 'café CHECK(x)' ) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_bin")
    }
}

extension DDLTests {
    func testIgnoredCheckJournalRetainsSourceAndRuleWithoutNewSchema() throws {
        #if os(Linux)
        let helpers=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helpers=ApplyTests()
        #endif
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let store=try StateStore(configuration:helpers.config(parent.appendingPathComponent("state").path))
        let table=helpers.tables()[0],sql="ALTER TABLE poc.items ADD CHECK(id>0)"
        let status=Data([1,0,0,0,0,0,0,0,0,4,45,0,45,0,45,0,18,45,0])
        let group=ddlGroup(try helpers.groups()[0],sql:sql,status:status)
        let statement=try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:status),profile:.mysql57To84InnoDB)
        let plan=PreparedDDL(statement:statement,before:table,after:table,sql:"",rawSQL:Data(),compatibilityRules:[NativeReplicationRules.ignoredChecksRule])
        try store.begin(group);try store.ddlIntent(plan,event:group.events[1],coordinate:group.start)
        let db=store.directory.appendingPathComponent("state.sqlite")
        XCTAssertEqual(try helpers.sqlite(db,"SELECT target_sql,status FROM ddl_intents"),[["","PENDING"]])
        try store.complete(group,rowCount:0,ddl:plan)
        XCTAssertEqual(try helpers.sqlite(db,"SELECT before_schema_id=after_schema_id,status FROM ddl_intents"),[["1","DONE"]])
        XCTAssertEqual(try helpers.sqlite(db,"SELECT COUNT(*),SUM(current) FROM schemas"),[["1","1"]])
        XCTAssertEqual(try helpers.sqlite(db,"SELECT source_sql,json_extract(context_json,'$.nativeCompatibilityRules[0]'),json_extract(context_json,'$.targetSQLBase64') FROM ddl_details"),[[sql,NativeReplicationRules.ignoredChecksRule,""]])
    }
}
