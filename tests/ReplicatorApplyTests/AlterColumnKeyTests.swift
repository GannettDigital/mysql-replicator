import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class AlterColumnKeyTests: XCTestCase {
    private func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testAutoIncrementContextUsesNativeDefaultsAndLoggedValues() throws {
        let status=Data([1,0,0,0,0,0,0,0,0,4,45,0,45,0,45,0])
        func query(_ data:Data) -> QueryControl { .init(database:"poc",sql:Data(),errorCode:0,statusVariables:data) }
        let defaults=try QuerySessionContext(query:query(status))
        XCTAssertEqual(defaults.autoIncrementIncrement,1)
        XCTAssertEqual(defaults.autoIncrementOffset,1)
        let source=query(status+Data([3,3,0,2,0]))
        let explicit=try QuerySessionContext(query:source)
        XCTAssertEqual(explicit.autoIncrementIncrement,3)
        XCTAssertEqual(explicit.autoIncrementOffset,2)
        let diagnostic=DDLQueryContextDiagnostic(query:source)
        XCTAssertEqual(diagnostic?.autoIncrementIncrement,3)
        XCTAssertEqual(diagnostic?.autoIncrementOffset,2)
    }
    func testInlinePrimaryKeysUseColumnAndKeyActions() throws {
        let column=ApplyColumn(name:"id",type:"int",nullable:false,collation:nil)
        let table=TableName(database:"poc",table:"t")
        XCTAssertEqual(try parse("ALTER TABLE t ADD id INT PRIMARY KEY FIRST"),.alter(table,[.add(column,.first),.primaryKey(["id"])]))
        XCTAssertEqual(try parse("ALTER TABLE t MODIFY id INT PRIMARY KEY AFTER v"),.alter(table,[.modify("id",column,.after("v")),.primaryKey(["id"])]))
        XCTAssertEqual(try parse("ALTER TABLE t CHANGE old id INT PRIMARY KEY"),.alter(table,[.modify("old",column,nil),.primaryKey(["id"])]))
        XCTAssertEqual(try parse("ALTER TABLE t ADD id INT PRIMARY KEY,DROP PRIMARY KEY"),.alter(table,[.add(column,.last),.primaryKey(["id"]),.primaryKey(nil)]))
    }
    func testImplicitRebuildValuesDoNotBecomeColumnDefaults() throws {
        guard case .add(_,let column,_) = try parse("ALTER TABLE t ADD n INT NOT NULL") else {return XCTFail("missing ADD")}
        XCTAssertFalse(column.nullable)
        XCTAssertNil(column.defaultValue)
        XCTAssertFalse(column.hasDefaultValue)
        guard case .alter(_,let actions)=try parse("ALTER TABLE t ADD id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY") else {return XCTFail("missing ALTER")}
        guard case .add(let auto,_) = actions[0] else {return XCTFail("missing column")}
        XCTAssertEqual(auto.extra,"auto_increment")
        XCTAssertFalse(auto.nullable)
        XCTAssertNil(auto.defaultValue)
        XCTAssertEqual(actions[1],.primaryKey(["id"]))
        XCTAssertThrowsError(try parse("ALTER TABLE t ADD n INT NOT NULL DEFAULT NULL"))
        XCTAssertThrowsError(try parse("ALTER TABLE t ADD n INT PRIMARY KEY PRIMARY KEY"))
    }
    func testCompoundIndexValidationWaitsForTheFinalDefinition() throws {
        var table=ApplyTable(database:"poc",table:"t",columns:[
            ApplyColumn(name:"id",type:"int",nullable:false,collation:nil,extra:"auto_increment")
        ],primaryKeyColumns:[])
        let index=ApplyIndex(name:"by_id",unique:false,parts:[.init(column:"id",prefix:nil)])
        table=try IndexChange.add(index).applying(to:table)
        XCTAssertThrowsError(try IndexChange.drop("by_id").applying(to:table))
        let intermediate=try IndexChange.drop("by_id").applying(to:table,validateResult:false)
        XCTAssertThrowsError(try intermediate.validate())
        XCTAssertNoThrow(try intermediate.replacing(primaryKey:["id"]).validate())
        guard case .alter(_,let actions)=try parse("ALTER TABLE t ADD KEY by_n(n),ADD n INT NOT NULL AUTO_INCREMENT") else {return XCTFail("missing ALTER")}
        XCTAssertEqual(actions.count,2)
    }
}
