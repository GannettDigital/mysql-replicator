import XCTest
import Foundation
@testable import ReplicatorApply

final class ViewRenameTests: XCTestCase {
    func testOrderedMixedNamespaceAndViewMetadata() throws {
        let a=TableName(database:"db",table:"a"),b=TableName(database:"db",table:"b"),tmp=TableName(database:"db",table:"tmp")
        let view=ViewDefinition(database:"db",table:"a",attributes:["VIEW_DEFINITION":"select `t`.`id` from `db`.`t`","DEFINER":"user@localhost","CHECK_OPTION":"LOCAL"])
        let table=ApplyTable(database:"db",table:"b",columns:[.init(name:"id",type:"int",nullable:false,collation:nil)],primaryKey:"id")
        let objects:[SQLNameKey:RenameObject]=[a.identity:.view(view),b.identity:.table(table)]
        let result=try TableRename.resolve([.init(from:a,to:tmp),.init(from:b,to:a),.init(from:tmp,to:b)],objects:objects) { try $0.renamed(to:$1) }
        XCTAssertEqual(result[a.identity]?.table,table.renamed(to:a))
        XCTAssertEqual(result[b.identity]?.view,try view.renamed(to:b))
        XCTAssertNil(result[tmp.identity])
        XCTAssertThrowsError(try TableRename.resolve([.init(from:a,to:b)],objects:objects) { try $0.renamed(to:$1) })
        XCTAssertThrowsError(try TableRename.resolve([.init(from:tmp,to:a)],objects:objects) { try $0.renamed(to:$1) })
        XCTAssertThrowsError(try view.renamed(to:.init(database:"other",table:"a")))
        let transition=ViewTransition(before:view,after:try view.renamed(to:b))
        let decoded=try JSONDecoder().decode(ViewTransition.self,from:JSONEncoder().encode(transition))
        XCTAssertEqual(decoded.before,view)
        XCTAssertEqual(decoded.after,try view.renamed(to:b))
        XCTAssertNotEqual(view,ViewDefinition(database:"db",table:"a",attributes:["VIEW_DEFINITION":"changed"]))
    }
}
