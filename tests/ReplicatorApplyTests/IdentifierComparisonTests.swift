import XCTest
import Foundation
@testable import ReplicatorApply

final class IdentifierComparisonTests:XCTestCase {
    func testNativeCaseMapDoesNotUseModernUnicodeNormalization() {
        XCTAssertEqual(NativeIdentifierLowercase.map.count,696)
        XCTAssertTrue(SQLIdentifier.equal("ID","id"))
        XCTAssertTrue(SQLIdentifier.equal("É","é"))
        XCTAssertTrue(SQLIdentifier.equal("İ","i"))
        XCTAssertFalse(SQLIdentifier.equal("İ","i\u{0307}"))
        XCTAssertFalse(SQLIdentifier.equal("é","e\u{0301}"))
        XCTAssertFalse(SQLIdentifier.equal("ſ","s"))
        XCTAssertFalse(SQLIdentifier.equal("Ⱥ","ⱥ")) // Modern pair absent from native map.
        XCTAssertNotEqual(SQLNameKey.table("poc","T"),SQLNameKey.table("poc","t"))
        XCTAssertEqual(SQLIdentifier.keyword("select"),"SELECT")
        XCTAssertEqual(SQLIdentifier.keyword("ſelect"),"")
        XCTAssertEqual(DDLToken(text:"ſelect").keyword,"")
    }
    func testReferencesUseNativeCaseButDefinitionsRetainBytes() throws {
        let columns=[ApplyColumn(name:"id",type:"int",nullable:false,collation:nil),ApplyColumn(name:"Value",type:"int",nullable:true,collation:nil)]
        let lower=ApplyTable(database:"poc",table:"t",columns:columns,primaryKey:"id",secondaryIndexes:[.init(name:"K",unique:false,parts:[.init(column:"Value",prefix:nil)])])
        let upper=ApplyTable(database:"poc",table:"t",columns:columns,primaryKey:"ID",secondaryIndexes:[.init(name:"K",unique:false,parts:[.init(column:"VALUE",prefix:nil)])])
        try upper.validate()
        XCTAssertEqual(upper.keyIndexes,[0])
        XCTAssertEqual(lower,upper)
        XCTAssertEqual(try IndexChange.drop("k").applying(to:upper).secondaryIndexes,[])
        var duplicate=upper
        duplicate.secondaryIndexes.append(.init(name:"k",unique:false,parts:[.init(column:"id",prefix:nil)]))
        XCTAssertThrowsError(try duplicate.validate())
        let duplicateColumns=upper.replacing(columns:columns+[.init(name:"value",type:"int",nullable:true,collation:nil)])
        XCTAssertThrowsError(try duplicateColumns.validate())
        XCTAssertNotEqual(columns[1],ApplyColumn(name:"VALUE",type:"int",nullable:true,collation:nil))
    }
    func testCreatePrimaryKeyCaseAndModifyAfterCase() throws {
        var parser=try DDLParser(Data("CREATE TABLE t(id INT,Value INT,PRIMARY KEY(ID),KEY K(VALUE))".utf8),database:"poc")
        guard case .create(let table,_)=try parser.parse() else { return XCTFail("expected CREATE") }
        try table.validate()
        XCTAssertFalse(table.columns[0].nullable)
        let modified=try table.modifying(.init(name:"VALUE",type:"bigint",nullable:true,collation:nil),placement:.after("ID"))
        XCTAssertEqual(modified.columns.map(\.name),["id","VALUE"])
        try modified.validate()
    }
}
