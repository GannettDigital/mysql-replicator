import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class NativeCharacterSetTests: XCTestCase {
    func testNativeInventoryAndWidths() throws {
        let entries=CharacterSetRegistry.collations.filter(\.supportsColumns)
        XCTAssertEqual(entries.count,221)
        XCTAssertEqual(Set(entries.map(\.characterSet)).count,40)
        for entry in entries {
            let column=ApplyColumn(name:"id",type:"varchar(12)",nullable:false,collation:entry.name57,characterSet:CharacterSetRegistry.charsetName(entry.characterSet,on:.mysql57))
            try column.validate()
            let type=try DMLColumnType(column)
            XCTAssertEqual(type.maximumBytes,12*CharacterSetRegistry.maximumBytesPerCharacter(entry.characterSet))
            let plan=try DMLSQLPlan(ApplyTable(database:"poc",table:"t",columns:[column],primaryKey:"id"))
            if type.interpretation.isEncodedText {
                XCTAssertTrue(plan.insert.contains("CONVERT(? USING \(entry.characterSet))"))
                XCTAssertTrue(plan.select.contains("CAST(`id` AS BINARY)"))
            }
        }
        for (charset,width) in [("ucs2",2),("utf16",4),("utf16le",4),("utf32",4),("gb18030",4),("ujis",3),("eucjpms",3),("big5",2),("sjis",2),("cp932",2),("cp1251",1)] {
            XCTAssertEqual(CharacterSetRegistry.maximumBytesPerCharacter(charset),width)
        }
        XCTAssertNil(CharacterSetRegistry.collation(id:17))
        XCTAssertNil(CharacterSetRegistry.collation(id:100))
        XCTAssertNil(CharacterSetRegistry.columnCollation(named:"utf8mb3_tolower_ci"))
    }
    func testWideCharactersUseCompleteCodeUnits() throws {
        for charset in ["ucs2","utf16","utf16le","utf32"] {
            let type=try DMLColumnType("varchar(4)",characterSet:charset)
            XCTAssertTrue(type.interpretation.isEncodedText)
            let bytes=Data([0x20,0x20,0,0])
            try type.validate(.binary(bytes))
            XCTAssertThrowsError(try type.validate(.binary(Data([0x20]))))
        }
        XCTAssertThrowsError(try ApplyColumn(name:"v",type:"varchar(16384)",nullable:true,collation:"utf16_bin",characterSet:"utf16").validate())
        try ApplyColumn(name:"v",type:"varchar(32767)",nullable:true,collation:"ucs2_bin",characterSet:"ucs2").validate()
    }
}
