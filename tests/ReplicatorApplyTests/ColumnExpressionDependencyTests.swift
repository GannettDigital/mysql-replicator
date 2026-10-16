import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ColumnExpressionDependencyTests: XCTestCase {
    private func check(_ sql:String,definition:String) throws {
        func parse(_ sql:String) throws -> DDLStatement {
            try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()),profile:.mysql57To84InnoDB)
        }
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,"+definition+")") else {return XCTFail("missing schema")}
        let actions:[AlterAction]
        switch try parse("ALTER TABLE t "+sql) {
        case .alter(_,let values):actions=values
        case .dropColumn(_,let name):actions=[.drop(name)]
        default:return XCTFail("missing actions: "+sql)
        }
        try ColumnExpressionDependencies.validate(table,actions:actions,rules:.init(sourceVersion:50700,targetVersion:80400))
    }
    func testFunctionalIndexRemovalUsesWholeStatement() throws {
        let definition="a INT,KEY ix ((a+1))"
        for sql in ["CHANGE a b INT,DROP INDEX ix","DROP INDEX ix,CHANGE a b INT","DROP a,DROP INDEX ix","DROP INDEX ix,DROP a","CHANGE a b INT,DROP INDEX ix,ADD INDEX ix ((b+2))","ADD INDEX ix ((b+2)),CHANGE a b INT,DROP INDEX ix"] {
            XCTAssertNoThrow(try check(sql,definition:definition),sql)
        }
        for sql in ["CHANGE a b INT","DROP a","CHANGE a b INT,RENAME INDEX ix TO iy"] {
            XCTAssertThrowsError(try check(sql,definition:definition)) { XCTAssertTrue(String(describing:$0).contains("functional index ix")) }
        }
        XCTAssertThrowsError(try check("CHANGE a b INT,DROP INDEX ix",definition:"a INT,KEY ix ((a+1)),KEY iy(id,(a+2))"))
    }
    func testDefaultsCanBeRemovedOrReplacedInEitherClauseOrder() throws {
        let definition="a INT,d INT DEFAULT (a+1)"
        for sql in ["CHANGE a b INT,ALTER d SET DEFAULT (b+2)","ALTER d SET DEFAULT (b+2),CHANGE a b INT","CHANGE a b INT,ALTER d DROP DEFAULT","ALTER d DROP DEFAULT,CHANGE a b INT","DROP a,ALTER d SET DEFAULT 8","ALTER d SET DEFAULT 8,DROP a","CHANGE a b INT,MODIFY d INT DEFAULT (b+2)","CHANGE a b INT,MODIFY d INT","DROP a,DROP d","DROP d,DROP a"] {
            XCTAssertNoThrow(try check(sql,definition:definition),sql)
        }
        for sql in ["CHANGE a b INT","DROP a"] {
            XCTAssertThrowsError(try check(sql,definition:definition)) { XCTAssertTrue(String(describing:$0).contains("unchanged default expression of column d")) }
        }
        XCTAssertThrowsError(try check("CHANGE a b INT,ALTER d DROP DEFAULT",definition:"a INT,d INT DEFAULT(a+1),e INT DEFAULT(a+2)"))
    }
    func testReferencesIgnoreLiteralsAndMatchIdentifierCase() throws {
        XCTAssertNoThrow(try check("CHANGE a b INT",definition:"a INT,d VARCHAR(10) DEFAULT ('`a`'),KEY ix ((id+LENGTH('`a`')))"))
        XCTAssertThrowsError(try check("CHANGE A b INT",definition:"a INT,d INT DEFAULT(a+1)"))
        XCTAssertNoThrow(try check("CHANGE A b INT,DROP INDEX IX,ALTER D DROP DEFAULT",definition:"a INT,d INT DEFAULT(a+1),KEY ix ((a+1))"))
    }
    func testRemovingDefaultDoesNotRemoveGeneratedDependency() throws {
        XCTAssertThrowsError(try check("CHANGE a b INT,ALTER d DROP DEFAULT",definition:"a INT,d INT DEFAULT(a+1),g INT AS(a+2) STORED")) {
            XCTAssertTrue(String(describing:$0).contains("unchanged generated column g"))
        }
    }
}
