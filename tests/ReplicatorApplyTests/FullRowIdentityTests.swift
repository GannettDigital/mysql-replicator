import XCTest
import Foundation
import MySQLNIO
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class FullRowIdentityTests: XCTestCase {
    func table() -> ApplyTable {
        .init(database:"poc",table:"t",columns:[.init(name:"n",type:"int",nullable:true),.init(name:"s",type:"varchar(20)",nullable:true,collation:"utf8mb4_unicode_ci"),.init(name:"j",type:"json",nullable:true)],primaryKeyColumns:[])
    }
    func testFullRowSQLUsesNullSafeExactTextAndOneRow() throws {
        let t=table();try t.validate()
        XCTAssertEqual(t.rowIdentity?.kind,.fullRow)
        let plan=try DMLSQLPlan(t)
        XCTAssertTrue(plan.select.contains("`n`<=>?"))
        XCTAssertTrue(plan.select.contains("CAST(`s` AS BINARY)<=>CAST(? AS BINARY)"))
        for sql in [plan.select,plan.delete,plan.update] { XCTAssertTrue(sql.hasSuffix(" LIMIT 1")) }
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(t)),t)
        var changed=try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(t))
        changed.savedRowIdentity = .init(kind:.fullRow,index:"",columns:["n"])
        XCTAssertThrowsError(try changed.validate())
    }
    func testJSONPredicateChecksStructureTypesAndExactValues() throws {
        let t=table(),types=try DMLTablePlan(t).columnTypes
        let document=try JSONDocument(text:#"{"a":[1,null,"x"],"b":{}}"#)
        let fields=try document.matchFields()
        XCTAssertEqual(fields.map(\.type),["OBJECT","ARRAY","INTEGER","NULL","STRING","OBJECT"])
        XCTAssertEqual(fields.compactMap(\.count),[2,3,0])
        let p=try FullRowPredicate.make(table:t,types:types,values:[.null,.text("a"),.json(document)],compatibility:.init(),bind:{ _ in .init(string:"bound") })
        XCTAssertTrue(p.sql.contains("`n` IS NULL"))
        XCTAssertTrue(p.sql.contains("JSON_LENGTH(JSON_EXTRACT(`j`,?))=?"))
        XCTAssertTrue(p.sql.contains("CAST(JSON_UNQUOTE(JSON_EXTRACT(`j`,?)) AS BINARY)=CAST(? AS BINARY)"))
        XCTAssertEqual(p.sql.filter{$0 == "?"}.count,p.binds.count)
        XCTAssertFalse(p.sql.contains(" LIMIT "))
        let zeros=try FullRowPredicate.make(table:t,types:types,values:[.null,.null,.json(JSONDocument(text:"[-0.0,0.0]"))],compatibility:.init(),bind:{ _ in .init(string:"bound") })
        XCTAssertTrue(zeros.sql.contains("ATAN2(JSON_UNQUOTE(JSON_EXTRACT(`j`,?)),-1)<0"))
        XCTAssertTrue(zeros.sql.contains("ATAN2(JSON_UNQUOTE(JSON_EXTRACT(`j`,?)),-1)>=0"))
        XCTAssertEqual(zeros.sql.filter{$0 == "?"}.count,zeros.binds.count)
    }
    func testSignedZeroAndDecimalPredicates() throws {
        let t=ApplyTable(database:"poc",table:"t",columns:[.init(name:"f",type:"float",nullable:true),.init(name:"d",type:"double",nullable:true),.init(name:"n",type:"decimal(30,2)",nullable:true)],primaryKeyColumns:[])
        let p=try FullRowPredicate.make(table:t,types:DMLTablePlan(t).columnTypes,values:[.float32(0x80000000),.float64(0),.decimal("9007199254740993.25")],compatibility:.init(),bind:{ _ in .init(string:"bound") })
        XCTAssertTrue(p.sql.contains("ATAN2(`f`,-1)<0"))
        XCTAssertTrue(p.sql.contains("ATAN2(`d`,-1)>=0"))
        XCTAssertTrue(p.sql.contains("`n`<=>CAST(? AS DECIMAL(30,2))"))
        XCTAssertEqual(p.binds.count,3)
    }
    func testFullRowRecoveryDoesNotCollapseDuplicates() throws {
        let t=table(), image:[DecodedValue]=[.signed(1),.null,.null]
        let rows=(0..<3).map { ordinal in
            Recovery.Row(ordinal:ordinal,status:ordinal == 0 ? "APPLIED" : "PENDING",schemaID:"schema",schema:t,sourceEventOffset:"10",sourceRow:ordinal,operation:"delete",beforeKey:nil,afterKey:nil,before:image,after:nil)
        }
        let group=Recovery.Group(sequence:1,gtid:"test:1",file:"binlog.000001",startPosition:"4",endPosition:"100",relayStart:0,relayEnd:100,rows:rows,expectations:try Recovery.fold(rows))
        XCTAssertTrue(group.expectations.isEmpty)
        XCTAssertEqual(group.fullRowChanges.map(\.ordinal),[0,1,2])
        XCTAssertEqual(group.fullRowChanges.map(\.before),[image,image,image])
        let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(group)) as! [String:Any]
        XCTAssertEqual((object["fullRowChanges"] as? [Any])?.count,3)
    }
}
