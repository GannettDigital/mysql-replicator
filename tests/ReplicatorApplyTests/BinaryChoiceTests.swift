import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class BinaryChoiceTests:XCTestCase {
    func testNativeHexAndBitLabelForms() throws {
        let sql="CREATE TABLE t(id INT PRIMARY KEY,e ENUM(0xF,X'ff',B'1',0b100000001,'a') CHARACTER SET binary DEFAULT X'ff')"
        guard case .create(let table,_)=try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data())) else { return XCTFail("missing CREATE") }
        XCTAssertEqual(try DMLColumnType(table.columns[1]).labels,[Data([15]),Data([255]),Data([1]),Data([1,1]),Data([97])])
        XCTAssertEqual(table.columns[1].choiceDefaultBytes,Data([255]))
        XCTAssertNil(table.columns[1].defaultValue)
        XCTAssertThrowsError(try SQLByteLiteral.decode("+1",radix:16))
        XCTAssertThrowsError(try SQLByteLiteral.decode("f",radix:16,allowOdd:false))
        XCTAssertThrowsError(try SQLByteLiteral.decode("2",radix:2))
    }
    func testExactBinaryLabelsAndDefaultsPersist() throws {
        let column=ApplyColumn(name:"e",type:"enum(X'ff',X'61')",nullable:false,collation:"binary",characterSet:"binary",choiceDefaultBytes:Data([255]))
        let exact=try ChoiceMetadata.resolved(column,labels:[Data([255]),Data([97])],display:["ignored","ignored"],defaultValue:nil,defaultOrdinal:1,defaultBytes:Data([255]))
        try exact.validate()
        XCTAssertEqual(exact.defaultValue,nil)
        XCTAssertEqual(exact.choiceDefaultBytes,Data([255]))
        XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self,from:JSONEncoder().encode(exact)),exact)
        let table=ApplyTable(database:"poc",table:"t",columns:[exact],primaryKey:"e")
        let plan=try DMLTablePlan(table)
        let wire=WireColumn(interpretation:.unsigned,type:247,maximumBytes:0,nullable:false,collation:63,primaryKey:true,name:"e",metadata:Data([247,1]),labels:[Data([255]),Data([97])])
        try plan.validate(wire:[wire])
    }
}
