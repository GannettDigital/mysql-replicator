import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class GeneratedColumnDependencyTests: XCTestCase {
    private func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    private func check(_ sql:String,target:UInt32 = 50700,definition:String = "id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED") throws {
        guard case .create(let table,_)=try parse("CREATE TABLE t("+definition+")"),
              case .alter(_,let actions)=try parse("ALTER TABLE t "+sql) else {return XCTFail("missing schema/actions")}
        try ColumnExpressionDependencies.validate(table,actions:actions,rules:.init(sourceVersion:50700,targetVersion:target))
    }
    func testRenameUsesAllExpressionChangesRegardlessOfClauseOrder() throws {
        for target:UInt32 in [50700,80400] {
            for sql in ["CHANGE a b INT,MODIFY g INT AS(b+2) STORED","MODIFY g INT AS(b+2) STORED,CHANGE a b INT","CHANGE a b INT,DROP g","DROP g,CHANGE a b INT","CHANGE a b INT,MODIFY g INT"] {
                XCTAssertNoThrow(try check(sql,target:target),sql)
            }
            XCTAssertThrowsError(try check("CHANGE a b INT,ADD note INT",target:target)) {
                XCTAssertTrue(String(describing:$0).contains("unchanged generated column g"))
            }
        }
    }
    func testDropUsesTargetVersionRatherThanSourceVersion() throws {
        for sql in ["DROP a,DROP g","DROP g,DROP a","DROP a,MODIFY g INT AS(id+2) STORED"] {
            XCTAssertThrowsError(try check(sql)) { XCTAssertTrue(String(describing:$0).contains("native error 3108")) }
            XCTAssertNoThrow(try check(sql,target:80400))
        }
        XCTAssertThrowsError(try check("DROP a,ADD note INT",target:80400))
        XCTAssertNoThrow(try check("DROP g,DROP a",target:80400))
    }
    func testReferencesAreIdentifiersNotLiteralSubstringsAndIgnoreCase() throws {
        XCTAssertNoThrow(try check("CHANGE a b INT,ADD note INT",definition:"id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED"))
        XCTAssertThrowsError(try check("CHANGE A b INT,ADD note INT"))
        XCTAssertThrowsError(try check("CHANGE a b INT,MODIFY g INT AS(b+1) STORED",definition:"id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(a+2) VIRTUAL"))
        XCTAssertNoThrow(try check("CHANGE a b INT,MODIFY g INT AS(b+1) STORED,DROP h",definition:"id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(a+2) VIRTUAL"))
    }
}
