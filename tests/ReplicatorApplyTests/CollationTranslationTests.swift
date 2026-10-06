import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class CollationTranslationTests: XCTestCase {
    let policy = CompatibilityPolicy(collations:["utf8mb4_0900_ai_ci":"utf8mb4_unicode_ci"])
    func translate(_ sql: String,mode: UInt64 = 0,defaultID: UInt32 = 255) throws -> (DDLStatement,String) {
        var parser = try DDLParser(Data(sql.utf8),database:"poc",sqlMode:mode)
        parser.compatibility = policy; parser.defaultUTF8MB4Collation = defaultID
        let statement = try parser.parse()
        return (statement,parser.translatedSQL(Data(sql.utf8)))
    }
    func testMappingIsExplicitSameCharsetAndBounded() throws {
        XCTAssertNoThrow(try policy.validate())
        XCTAssertEqual(policy.targetID(255),224)
        XCTAssertEqual(policy.targetID(46),46)
        XCTAssertEqual(CompatibilityPolicy().targetID(255),255)
        for (from,to) in [("utf8mb4_0900_as_cs","utf8mb4_bin"),("utf8mb4_0900_ai_ci","latin1_bin"),("utf8mb4_bin","utf8mb4_unicode_ci")] {
            XCTAssertThrowsError(try CompatibilityPolicy(collations:[from:to]).validate())
        }
    }
    func testEditsOnlyParsedCollationsPreservingLiteralBytesCommentsAndQuotedNames() throws {
        let sql = #"CREATE TABLE `utf8mb4_0900_ai_ci`(id INT PRIMARY KEY,v VARCHAR(80) COLLATE `utf8mb4_0900_ai_ci` DEFAULT 'utf8mb4_0900_ai_ci\n''é') /* COLLATE utf8mb4_0900_ai_ci */ DEFAULT COLLATE=utf8mb4_0900_ai_ci;"#
        let (statement,rewritten) = try translate(sql)
        XCTAssertEqual(rewritten,sql.replacingOccurrences(of:"COLLATE `utf8mb4_0900_ai_ci`",with:"COLLATE utf8mb4_unicode_ci").replacingOccurrences(of:"COLLATE=utf8mb4_0900_ai_ci",with:"COLLATE=utf8mb4_unicode_ci"))
        guard case .create(let table,_) = statement else { return XCTFail("missing table") }
        XCTAssertEqual(table.table,"utf8mb4_0900_ai_ci")
        XCTAssertEqual(table.columns[1].collation,"utf8mb4_unicode_ci")
        XCTAssertEqual(table.columns[1].defaultValue,"utf8mb4_0900_ai_ci\n'é")
        var strict = try DDLParser(Data(sql.utf8),database:"poc")
        _ = try strict.parse()
        XCTAssertEqual(strict.translatedSQL(Data(sql.utf8)),sql)
        let ansi = #"CREATE TABLE "t"(id INT PRIMARY KEY,v VARCHAR(40) CHARACTER SET utf8mb4 DEFAULT 'a\nb')"#
        let (_,text) = try translate(ansi,mode:4 | (1 << 20))
        XCTAssertEqual(text,ansi.replacingOccurrences(of:"SET utf8mb4",with:"SET utf8mb4 COLLATE utf8mb4_unicode_ci"))
    }
    func testTranslationRebasesSlicedInputForReplacementsAndInsertions() throws {
        let cases = [
            ("CREATE DATABASE d COLLATE utf8mb4_0900_ai_ci",
             "CREATE DATABASE d COLLATE utf8mb4_unicode_ci"),
            ("CREATE DATABASE d CHARACTER SET utf8mb4",
             "CREATE DATABASE d CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"),
            ("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) CHARACTER SET utf8mb4 DEFAULT 'é') COLLATE utf8mb4_0900_ai_ci",
             "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT 'é') COLLATE utf8mb4_unicode_ci"),
            ("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) COLLATE utf8mb4_0900_ai_ci) COLLATE utf8mb4_0900_ai_ci",
             "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) COLLATE utf8mb4_unicode_ci) COLLATE utf8mb4_unicode_ci"),
            ("CREATE DATABASE d", "CREATE DATABASE d")
        ]
        for (sql, expected) in cases {
            let full = Data(("prefix" + sql + "suffix").utf8)
            let sliced = full.dropFirst(6).dropLast(6)
            XCTAssertEqual(sliced.startIndex, 6)
            var parser = try DDLParser(sliced, database: "poc")
            parser.compatibility = policy
            _ = try parser.parse()
            XCTAssertEqual(parser.translatedSQL(sliced), expected, sql)
            XCTAssertEqual(parser.translatedSQL(Data(sql.utf8)), expected, sql)
            XCTAssertEqual(String(decoding: sliced, as: UTF8.self), sql)
        }
    }
    func testCharsetOnlyDefaultsAreScopedToEachDeclaration() throws {
        for sql in ["CREATE DATABASE d CHARACTER SET=utf8mb4", "ALTER SCHEMA d CHARSET utf8mb4", "ALTER TABLE t ADD v VARCHAR(20) CHARACTER SET utf8mb4 DEFAULT 'x'", "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) CHARACTER SET utf8mb4) CHARSET=utf8mb4"] {
            XCTAssertEqual(try translate(sql).1,sql.replacingOccurrences(of:"utf8mb4",with:"utf8mb4 COLLATE utf8mb4_unicode_ci"))
            XCTAssertEqual(try translate(sql,defaultID:45).1,sql)
        }
        let sql = "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) CHARACTER SET utf8mb4) CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
        XCTAssertEqual(try translate(sql).1,"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci) CHARSET=utf8mb4 COLLATE=utf8mb4_bin")
        for sql in ["CREATE DATABASE d", "CREATE TABLE t LIKE original", "CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(20))", "CREATE DATABASE d COLLATE utf8mb4_bin CHARACTER SET utf8mb4"] {
            XCTAssertEqual(try translate(sql).1,sql)
        }
        XCTAssertThrowsError(try translate("CREATE DATABASE d COLLATE"))
        XCTAssertThrowsError(try translate("CREATE DATABASE d /*!80000 COLLATE utf8mb4_0900_ai_ci */"))
    }
    func testMappedWireStillRejectsUnconfiguredCollationsAndCacheChanges() throws {
        let table = ApplyTable(database:"poc",table:"t",columns:[ApplyColumn(name:"id",type:"varchar(20)",nullable:false,collation:"utf8mb4_unicode_ci")],primaryKey:"id")
        func wire(_ id: UInt32) -> [WireColumn] { [WireColumn(interpretation:.utf8,type:15,maximumBytes:80,nullable:false,collation:id,primaryKey:true,name:"id")] }
        let mapped = try DMLTablePlan(table,compatibility:policy)
        XCTAssertNoThrow(try mapped.validate(wire:wire(255)))
        XCTAssertNoThrow(try mapped.validate(wire:wire(224)))
        XCTAssertThrowsError(try mapped.validate(wire:wire(46)))
        XCTAssertThrowsError(try mapped.validate(wire:wire(309)))
        XCTAssertThrowsError(try DMLTablePlan(table).validate(wire:wire(255)))
    }
}

extension DDLTests {
    func testMultiRenameSimulatesLeftToRightAndJournalsSwapAtomically() throws {
        #if os(Linux)
        let f = ResumeTests(name:"fixtures",testClosure:{_ in})
        #else
        let f = ResumeTests()
        #endif
        let path = try f.directory(),config = try f.config(path.path)
        let original = f.helper.tables()[0], a = TableName(database:"poc",table:"a"), b = TableName(database:"poc",table:"b")
        let first = original.renamed(to:a), second = original.replacing(columns:Array(original.columns.prefix(2))).renamed(to:b)
        let sql = "RENAME TABLE a TO spare, b TO a, spare TO b"
        guard case .renameMany(let renames) = try parse(sql) else { return XCTFail("missing renames") }
        let changes = try TableRename.transitions(renames,schemas:[a.identity:first,b.identity:second])
        XCTAssertEqual(changes.count,2)
        XCTAssertEqual(changes[0].after,second.renamed(to:a))
        XCTAssertEqual(changes[1].after,first.renamed(to:b))
        XCTAssertThrowsError(try TableRename.transitions([.init(from:a,to:b)],schemas:[a.identity:first,b.identity:second]))
        XCTAssertThrowsError(try TableRename.transitions(renames,schemas:[a.identity:first]))
        XCTAssertThrowsError(try parse("RENAME TABLE a TO x, otherdb.b TO otherdb.y"))
        let group = ddlGroup(try f.helper.groups()[0],sql:sql)
        let plan = PreparedDDL(statement:.renameMany(renames),before:nil,after:nil,sql:sql,additional:changes)
        let db = path.appendingPathComponent("state.sqlite")
        do {
            let state = try StateStore(configuration:config)
            try state.bindTargetIdentity(f.target); try state.begin(group)
            try state.ddlIntent(plan,event:group.events[1],coordinate:group.start)
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT COUNT(*) FROM ddl_details"),[["1"]])
            // If checkpoint persistence fails, all current schemas stay old and
            // the committed intent remains pending; no partly retired namespace.
            try f.write(path,"CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'fixture'); END")
            XCTAssertThrowsError(try state.complete(group,rowCount:0,ddl:plan))
            XCTAssertEqual(Set(state.currentSchemas.map(\.table)),Set(["a","b"]))
            XCTAssertEqual(try f.helper.sqlite(db,"SELECT COUNT(*) FROM schemas WHERE current=1"),[["2"]])
            try f.write(path,"DROP TRIGGER fail_checkpoint")
            try state.complete(group,rowCount:0,ddl:plan); try state.stopped()
        }
        let reopened = try StateStore(configuration:config,initialize:false)
        XCTAssertEqual(reopened.currentSchemas.sorted{$0.table < $1.table},[second.renamed(to:a),first.renamed(to:b)])
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT COUNT(*),SUM(current) FROM schemas"),[["4","2"]])
        XCTAssertEqual(try f.helper.sqlite(db,"SELECT source_sql,target_sql,status FROM ddl_details JOIN ddl_intents USING(gtid)"),[[sql,sql,"DONE"]])
    }
}

extension ResumeTests {
    func testCompatibilityPolicyIsPinnedAcrossRestartAndLegacyMigration() throws {
        let path = try directory(),mapping = ["utf8mb4_0900_ai_ci":"utf8mb4_unicode_ci"]
        let configured = try helper.config(path.path,collations:mapping)
        try seed(configured)
        do { _ = try StateStore(configuration:configured,initialize:false) }
        for changes in [[:],["utf8mb4_0900_ai_ci":"utf8mb4_bin"]] {
            XCTAssertThrowsError(try StateStore(configuration:helper.config(path.path,collations:changes),initialize:false)) {
                XCTAssertTrue(String(describing:$0).contains("differs from saved state"))
            }
        }
        let legacy = try directory(),strict = try config(legacy.path)
        try seed(strict)
        try write(legacy,"DROP TABLE ddl_details; DROP TABLE compatibility; PRAGMA user_version=7")
        XCTAssertThrowsError(try StateStore(configuration:helper.config(legacy.path,collations:mapping),initialize:false))
        XCTAssertEqual(try helper.sqlite(legacy.appendingPathComponent("state.sqlite"),"PRAGMA user_version"),[["7"]])
        do { _ = try StateStore(configuration:strict,initialize:false) }
        XCTAssertEqual(try helper.sqlite(legacy.appendingPathComponent("state.sqlite"),"PRAGMA user_version"),[["8"]])
        XCTAssertEqual(try helper.sqlite(legacy.appendingPathComponent("state.sqlite"),"SELECT policy_json FROM compatibility"),[["{\"collations\":{}}"]])
    }
}
