import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ForeignKeyTests: XCTestCase {
    func parse(_ sql: String, profile: ReplicationProfile = .mysql57To84InnoDB) throws -> DDLStatement {
        try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()),profile:profile)
    }
    func schema(_ definition: String) throws -> ApplyTable {
        guard case .create(let table,_) = try parse("CREATE TABLE "+definition) else { throw ApplyError("missing table") }; return table
    }
    func testNamedAndCompositeForeignKeysAndImplicitIndexes() throws {
        let child = try schema("child(id INT PRIMARY KEY,a INT,b INT,CONSTRAINT fk FOREIGN KEY(a,b) REFERENCES parent(a,b) ON UPDATE CASCADE ON DELETE SET NULL)")
        XCTAssertEqual(child.foreignKeys.first?.columns,["a","b"])
        XCTAssertEqual(child.foreignKeys.first?.referencedColumns,["a","b"])
        XCTAssertEqual(child.foreignKeys.first?.onUpdate,"CASCADE")
        XCTAssertEqual(child.foreignKeys.first?.onDelete,"SET NULL")
        XCTAssertEqual(child.secondaryIndexes.first?.name,"fk")
        let parent = try schema("parent(a INT,b INT,PRIMARY KEY(a,b))")
        XCTAssertNoThrow(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter()))
    }
    func testUnnamedConstraintUsesGeneratedNameAndExistingIndex() throws {
        let table = try schema("child(id INT PRIMARY KEY,pid INT,KEY existing(pid),FOREIGN KEY(pid) REFERENCES parent(id))")
        XCTAssertEqual(table.foreignKeys.first?.name,"child_ibfk_1")
        XCTAssertEqual(table.secondaryIndexes.map(\.name),["existing"])
        let automatic = try schema("child(id INT PRIMARY KEY,pid INT,FOREIGN KEY(pid) REFERENCES parent(id))")
        XCTAssertEqual(automatic.secondaryIndexes.map(\.name),["pid"])
    }
    func testSchemaHistoryRoundTripAndLegacyDefault() throws {
        let child = try schema("child(id INT PRIMARY KEY,pid INT,CONSTRAINT fk FOREIGN KEY(pid) REFERENCES parent(id))")
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(child)),child)
        let plain = try schema("parent(id INT PRIMARY KEY)")
        let data = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("foreignKeys"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:data).foreignKeys,[])
        XCTAssertEqual(child.replacing(columns:child.columns).foreignKeys,child.foreignKeys)
    }
    func testCompleteUniqueParentKeyRequired() throws {
        let child = try schema("child(id INT PRIMARY KEY,pid INT,CONSTRAINT fk FOREIGN KEY(pid) REFERENCES parent(a))")
        for definition in ["parent(id INT PRIMARY KEY,a INT,KEY(a))","parent(a INT,b INT,PRIMARY KEY(a,b))"] {
            let parent = try schema(definition)
            XCTAssertThrowsError(try ForeignKeyGraph.validate(child.foreignKeys,tables:[child.identity:child,parent.identity:parent],filter:TableFilter())) {
                XCTAssertTrue(String(describing:$0).contains("complete unique parent key"))
            }
        }
    }
    func testCyclesAndFilterSplitsAreRejected() throws {
        let child = try schema("child(id INT PRIMARY KEY,pid INT,CONSTRAINT fk FOREIGN KEY(pid) REFERENCES parent(id))")
        let parent = try schema("parent(id INT PRIMARY KEY,pid INT,CONSTRAINT fk FOREIGN KEY(pid) REFERENCES child(id))")
        let tables = [child.identity:child,parent.identity:parent]
        XCTAssertThrowsError(try ForeignKeyGraph.validate(child.foreignKeys+parent.foreignKeys,tables:tables,filter:TableFilter())) {
            XCTAssertTrue(String(describing:$0).contains("cyclic"))
        }
        for pattern in ["poc.parent","poc.child"] {
            XCTAssertThrowsError(try ForeignKeyGraph.validate(child.foreignKeys,tables:tables,filter:TableFilter([pattern])))
        }
        let query = QueryControl(database:"poc",sql:Data("CREATE TABLE child(id INT PRIMARY KEY,pid INT,FOREIGN KEY(pid) REFERENCES parent(id))".utf8),errorCode:0,statusVariables:Data())
        XCTAssertThrowsError(try TableFilter(["poc.child"]).ignores(query))
        XCTAssertThrowsError(try TableFilter(["poc.parent"]).ignores(query))
        XCTAssertTrue(try TableFilter(["poc.%"]).ignores(query))
    }
    func testParserRejectsUnqualifiedRelationshipsAndMyISAM() throws {
        for sql in ["CREATE TABLE t(id INT PRIMARY KEY,pid INT,FOREIGN KEY(pid) REFERENCES t(id))", "CREATE TABLE t(id INT PRIMARY KEY,pid INT,FOREIGN KEY ix(pid) REFERENCES p(id))", "CREATE TABLE t(id INT PRIMARY KEY,pid INT,FOREIGN KEY(pid) REFERENCES p(id) MATCH FULL)"] {
            XCTAssertThrowsError(try parse(sql))
        }
        for profile in [ReplicationProfile.mysql84To57MyISAM,.mysql57To57MyISAM] {
            XCTAssertThrowsError(try parse("ALTER TABLE t ADD FOREIGN KEY(id) REFERENCES p(id)",profile:profile))
        }
        guard case .alter(_,let actions) = try parse("ALTER TABLE child DROP FOREIGN KEY old_fk,ADD CONSTRAINT new_fk FOREIGN KEY(id) REFERENCES parent(id)") else { return XCTFail("missing ALTER") }
        XCTAssertEqual(actions.count,2)
    }
    func testQueryContextPreservesForeignKeyCheckFlag() throws {
        for disabled in [false,true] {
            // Q_FLAGS2, Q_SQL_MODE, Q_CHARSET. MySQL query_options.h uses bit 26.
            let status = Data([0,0,0,0,disabled ? 4 : 0, 1,0,0,0,0,0,0,0,0, 4,45,0,45,0,45,0])
            let query = QueryControl(database:"poc",sql:Data("CREATE TABLE t(id INT PRIMARY KEY)".utf8),errorCode:0,statusVariables:status)
            XCTAssertEqual(try QuerySessionContext(query:query).foreignKeyChecks,!disabled)
        }
    }
    func testImplicitIndexNameCollisionAndReplacementRefusal() throws {
        let child = try schema("child(id INT PRIMARY KEY,pid INT,n INT,KEY pid(n),FOREIGN KEY(pid) REFERENCES parent(id))")
        XCTAssertEqual(child.secondaryIndexes.map(\.name),["pid","pid_2"])
        XCTAssertThrowsError(try IndexChange.add(ApplyIndex(name:"wider",unique:false,parts:[.init(column:"pid",prefix:nil),.init(column:"id",prefix:nil)])).applying(to:child))
    }
    func testGeneratedIndexAlternativesAreNarrowAndJournaled() throws {
        let before = try schema("child(id INT PRIMARY KEY,pid INT,KEY pid(pid))")
        let key = ApplyForeignKey(name:"restored_fk",database:"poc",table:"child",columns:["pid"],referencedDatabase:"poc",referencedTable:"parent",referencedColumns:["id"],onDelete:"CASCADE")
        let after = try before.addingForeignKey(key,indexName:nil)
        let alternatives = try ForeignKeyGraph.indexAlternatives(before:before,after:after,actions:[.addForeignKey(key,nil)])
        XCTAssertEqual(after.secondaryIndexes.map(\.name),["pid"])
        XCTAssertEqual(alternatives.count,1)
        XCTAssertEqual(alternatives[0].secondaryIndexes.map(\.name),["restored_fk"])
        XCTAssertEqual(alternatives[0].foreignKeys,after.foreignKeys)
        XCTAssertEqual(alternatives[0].columns,after.columns)
        let transition = SchemaTransition(before:before,after:after,afterAlternatives:alternatives)
        let saved = try JSONDecoder().decode(SchemaTransition.self,from:JSONEncoder().encode(transition))
        XCTAssertEqual(saved.afterAlternatives,alternatives)
        XCTAssertThrowsError(try ForeignKeyGraph.indexAlternatives(before:before,after:after,actions:[.addForeignKey(key,nil),.dropForeignKey("old")]))
        var unique = before
        unique.secondaryIndexes = [ApplyIndex(name:"unique_pid",unique:true,parts:[.init(column:"pid",prefix:nil)])]
        XCTAssertTrue(try ForeignKeyGraph.indexAlternatives(before:unique,after:unique.addingForeignKey(key,indexName:nil),actions:[.addForeignKey(key,nil)]).isEmpty)
    }
    func testComponentAndGeneratedNameLimitsFailBeforeExecution() throws {
        let keys = (0..<64).map { ApplyForeignKey(name:"fk",database:"poc",table:"c"+String($0),columns:["id"],referencedDatabase:"poc",referencedTable:"p",referencedColumns:["id"]) }
        XCTAssertThrowsError(try ForeignKeyGraph.validate(keys,tables:[:],filter:TableFilter())) {
            XCTAssertTrue(String(describing:$0).contains("exceeds 64 tables"))
        }
        XCTAssertThrowsError(try schema("child(id INT PRIMARY KEY,pid INT,CONSTRAINT child_ibfk_\(Int.max) FOREIGN KEY(pid) REFERENCES parent(id),FOREIGN KEY(pid) REFERENCES parent(id))"))
    }
    func testConnectedEvidenceIncludesIndirectCascadesAndRename() throws {
        let child = try schema("child(id INT PRIMARY KEY,pid INT,FOREIGN KEY(pid) REFERENCES parent(id) ON DELETE CASCADE)")
        let grand = try schema("grand(id INT PRIMARY KEY,pid INT,CONSTRAINT g FOREIGN KEY(pid) REFERENCES child(id) ON DELETE CASCADE)")
        let edges = child.foreignKeys+grand.foreignKeys
        XCTAssertEqual(ForeignKeyGraph.component("poc\0parent",in:edges).count,2)
        let rename = TableRename(from:.init(database:"poc",table:"child"),to:.init(database:"poc",table:"renamed"))
        let changed = edges.map { $0.renamed(rename) }
        XCTAssertEqual(changed[0].name,"renamed_ibfk_1")
        XCTAssertEqual(changed[1].referencedTable,"renamed")
    }
}
