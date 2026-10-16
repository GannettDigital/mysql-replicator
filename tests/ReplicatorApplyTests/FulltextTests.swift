import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class FulltextTests: XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testFulltextDDLNormalizesIgnoredPrefixAndRetainsParser() throws {
        let key=ApplyIndex(name:"ft",unique:false,parts:[.init(column:"body",prefix:nil,direction:nil)],type:"FULLTEXT",parser:"ngram")
        for sql in ["CREATE FULLTEXT INDEX ft ON t(body(2)) WITH PARSER ngram","ALTER TABLE t ADD FULLTEXT KEY ft(body) WITH PARSER ngram"] {
            XCTAssertEqual(try parse(sql),.indexes(.init(database:"poc",table:"t"),.add(key)))
        }
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,body TEXT,FULLTEXT KEY ft(body(0) DESC) WITH PARSER ngram)") else { return XCTFail() }
        XCTAssertEqual(table.secondaryIndexes,[key])
        let bytes=try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(ApplyIndex.self,from:bytes),key)
        XCTAssertThrowsError(try parse("CREATE FULLTEXT INDEX ft USING BTREE ON t(body)"))
        XCTAssertThrowsError(try parse("CREATE INDEX ft ON t(body) WITH PARSER ngram"))
    }
    func testNativeMetadataReadsVersionedParserButDoesNotEnableSourceComments() throws {
        let sql="CREATE TABLE `t` (`id` int,`body` text COMMENT 'WITH PARSER fake',FULLTEXT KEY `normal` (`body`),FULLTEXT KEY `ft` (`body`) COMMENT 'FULLTEXT KEY fake' /*!50100 WITH PARSER `ngram` */) ENGINE=InnoDB"
        let metadata=try FulltextMetadata.parsers(Data(sql.utf8))
        XCTAssertEqual(metadata.count,2)
        XCTAssertNil(try XCTUnwrap(metadata[SQLIdentifier.key("normal")]).parser)
        XCTAssertEqual(metadata[SQLIdentifier.key("ft")]?.parser,"ngram")
        XCTAssertThrowsError(try DDLTokens.lex(Data(sql.utf8)))
    }
    func testNativeFulltextColumnRestrictions() throws {
        var table=ApplyTable(database:"poc",table:"t",columns:[.init(name:"id",type:"int",nullable:false,collation:nil),.init(name:"body",type:"text",nullable:true,collation:"utf8mb4_bin",characterSet:"utf8mb4")],primaryKey:"id")
        table.secondaryIndexes=[.init(name:"ft",unique:false,parts:[.init(column:"body",prefix:nil,direction:nil)],type:"FULLTEXT")]
        XCTAssertNoThrow(try table.validate())
        for (type,charset,collation) in [("blob","binary","binary"),("int","utf8mb4","utf8mb4_bin"),("text","utf16","utf16_bin")] {
            var columns=table.columns;columns[1] = .init(name:"body",type:type,nullable:true,collation:collation,characterSet:charset)
            let invalid=ApplyTable(database:"poc",table:"t",columns:columns,primaryKey:"id",secondaryIndexes:table.secondaryIndexes)
            XCTAssertThrowsError(try invalid.validate())
        }
        var changed=table.secondaryIndexes[0];changed.parser="ngram"
        XCTAssertNotEqual(changed,table.secondaryIndexes[0])
    }
}
