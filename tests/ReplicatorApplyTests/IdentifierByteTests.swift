import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class IdentifierByteTests:XCTestCase {
    let composed="é",decomposed="e\u{0301}"
    func testCacheKeysDoNotMergeNativeNames() {
        XCTAssertEqual(composed,decomposed) // Swift canonical equivalence is the problem.
        let a=SQLNameKey.table("poc",composed),b=SQLNameKey.table("poc",decomposed)
        XCTAssertNotEqual(a,b)
        XCTAssertEqual([a:1,b:2].count,2)
        XCTAssertNotEqual(SQLNameKey.table(composed,"t"),SQLNameKey.table(decomposed,"t"))
        XCTAssertNotEqual(TableName(database:"poc",table:composed),TableName(database:"poc",table:decomposed))
    }
    func testWireNameChangesCannotReuseValidation() {
        let a=WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:true,name:composed)
        let b=WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:true,name:decomposed)
        XCTAssertNotEqual(a,b)
    }
    func testSavedSchemaFormatDoesNotContainCacheKeys() throws {
        let a=ApplyTable(database:"poc",table:composed,columns:[.init(name:"id",type:"int",nullable:false,collation:nil)],primaryKey:"id")
        let b=ApplyTable(database:"poc",table:decomposed,columns:a.columns,primaryKey:"id")
        XCTAssertNotEqual(a,b)
        let data=try JSONEncoder().encode(a)
        XCTAssertNil((try JSONSerialization.jsonObject(with:data) as! [String:Any])["identity"])
        let decoded=try JSONDecoder().decode(ApplyTable.self,from:data)
        XCTAssertEqual(decoded,a)
        XCTAssertEqual(decoded.identity,a.identity)
        XCTAssertNotEqual(decoded.identity,b.identity)
    }
    func testSchemaComparisonsKeepNamesAndExpressionBytes() {
        let a=ApplyIndex(name:composed,unique:false,parts:[.init(column:"id",prefix:nil)])
        let b=ApplyIndex(name:decomposed,unique:false,parts:a.parts)
        XCTAssertNotEqual(a,b)
        XCTAssertNotEqual(ApplyIndexPart(column:composed,prefix:nil),ApplyIndexPart(column:decomposed,prefix:nil))
        XCTAssertNotEqual(ApplyPartition(name:"p0",method:"LIST COLUMNS",expression:"`v`",description:"'"+composed+"'"),ApplyPartition(name:"p0",method:"LIST COLUMNS",expression:"`v`",description:"'"+decomposed+"'"))
        let columns=[ApplyColumn(name:composed,type:"int",nullable:false,collation:nil),ApplyColumn(name:decomposed,type:"int",nullable:false,collation:nil)]
        XCTAssertNotEqual(ApplyTable(database:"poc",table:"t",columns:columns,primaryKey:composed),ApplyTable(database:"poc",table:"t",columns:columns,primaryKey:decomposed))
        XCTAssertNotEqual(DDLToken(text:composed,identifier:true),DDLToken(text:decomposed,identifier:true))
    }
}
