import XCTest
import Foundation
@testable import ReplicatorApply

final class TextDefaultTests:XCTestCase {
    func testTextDefaultsKeepNativeLiteralForm() throws {
        var parser=try DDLParser(Data("CREATE TABLE t(id INT PRIMARY KEY,n CHAR(8) DEFAULT 1e2,q VARCHAR(8) DEFAULT '1e2',l VARCHAR(8) CHARACTER SET latin1 DEFAULT X'ff00')".utf8),database:"poc")
        guard case .create(let table,_)=try parser.parse() else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.columns[1].numericDefaultLiteral,true)
        XCTAssertNil(table.columns[2].numericDefaultLiteral)
        XCTAssertEqual(table.columns[1].defaultValue,table.columns[2].defaultValue)
        XCTAssertEqual(table.columns[3].binaryDefaultBytes,Data([255,0]))
    }
    func testCanonicalCharacterPaddingAndSupplementaryDefaults() throws {
        for (type,expected) in [("char(8)","😀\0"),("varchar(8)","😀\0  ")] {
            let column=ApplyColumn(name:"c",type:type,nullable:true,collation:"utf8mb4_bin",characterSet:"utf8mb4")
            let resolved=try TextDefaultMetadata.resolved(column,utf8:Data("😀\0  ".utf8))
            XCTAssertEqual(resolved.defaultValue,expected)
            XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self,from:JSONEncoder().encode(resolved)),resolved)
            XCTAssertThrowsError(try TextDefaultMetadata.resolved(column,utf8:Data([255])))
        }
        let decomposed=ApplyColumn(name:"c",type:"char(8)",nullable:true,collation:"utf8mb4_bin",characterSet:"utf8mb4")
        let exact=try TextDefaultMetadata.resolved(decomposed,utf8:Data("e\u{0301}  ".utf8))
        XCTAssertEqual(exact.defaultValue.map { Data($0.utf8) },Data([0x65,0xcc,0x81]))
        let wide=ApplyColumn(name:"c",type:"char(8)",nullable:true,collation:"utf16_bin",characterSet:"utf16")
        XCTAssertEqual(try TextDefaultMetadata.resolved(wide,utf8:Data("中\u{00a0} ".utf8)).defaultValue,"中\u{00a0}")
    }
}
