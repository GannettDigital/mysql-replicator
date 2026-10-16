import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class TableEncodingTests: XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testDefaultAndConversionHaveSeparateActions() throws {
        let table=TableName(database:"poc",table:"t")
        for prefix in ["DEFAULT CHARACTER SET=","CHARSET "] {
            XCTAssertEqual(try parse("ALTER TABLE t "+prefix+"latin1 COLLATE latin1_bin"),.alter(table,[.encoding(.init(characterSet:"latin1",collation:"latin1_bin",convert:false))]))
        }
        XCTAssertEqual(try parse("ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),.alter(table,[.encoding(.init(characterSet:"utf8mb4",collation:"utf8mb4_bin",convert:true))]))
        XCTAssertEqual(try parse("ALTER TABLE t COLLATE=latin1_bin"),.alter(table,[.encoding(.init(characterSet:nil,collation:"latin1_bin",convert:false))]))
        XCTAssertNoThrow(try parse("ALTER TABLE t ADD v VARCHAR(30), DEFAULT CHARSET=latin1 COMMENT='kept'"))
        XCTAssertNoThrow(try parse("ALTER TABLE t DEFAULT CHARSET=DEFAULT"))
        guard case .alter(_,let compound)=try parse("ALTER TABLE t CONVERT TO CHARACTER SET latin1 COLLATE latin1_bin, DEFAULT COLLATE latin1_swedish_ci") else { return XCTFail("missing compound ALTER") }
        XCTAssertEqual(compound,[.encoding(.init(characterSet:"latin1",collation:"latin1_bin",convert:true)),.encoding(.init(characterSet:nil,collation:"latin1_swedish_ci",convert:false))])
        XCTAssertNoThrow(try parse("ALTER TABLE t CONVERT TO CHARSET DEFAULT, ALGORITHM=COPY"))
    }
    func testMalformedClausesDoNotBypassTheParser() throws {
        for suffix in ["CONVERT TO COLLATE latin1_bin","CONVERT latin1","DEFAULT nonsense","CHARACTER latin1","CHARSET=","CONVERT TO CHARACTER SET latin1; DROP TABLE t"] {
            XCTAssertThrowsError(try parse("ALTER TABLE t "+suffix),suffix)
        }
    }
    func testConversionUsesExplicitCollationPolicy() throws {
        for clause in ["DEFAULT CHARACTER SET utf8mb4","CONVERT TO CHARACTER SET utf8mb4","CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"] {
            let sql=Data(("ALTER TABLE t "+clause).utf8)
            var parser=try DDLParser(query:.init(database:"poc",sql:sql,errorCode:0,statusVariables:Data()))
            parser.compatibility = .init(collations:["utf8mb4_0900_ai_ci":"utf8mb4_bin"])
            parser.defaultUTF8MB4Collation=255
            guard case .alter(_,let actions)=try parser.parse(),case .encoding(let encoding)=actions[0] else { return XCTFail("missing encoding") }
            XCTAssertEqual(encoding.collation,"utf8mb4_bin")
            XCTAssertTrue(parser.translatedSQL(sql).hasSuffix("COLLATE utf8mb4_bin"))
        }
    }
    func testDefaultResolutionFollowsNativeTableAndSessionScopes() {
        let table=DDLEncoding(characterSet:"utf8mb4",collation:"utf8mb4_bin")
        let session=DDLEncoding(characterSet:"latin1",collation:"latin1_bin")
        let cases:[(DDLTableEncoding,DDLTableEncoding)] = [
            (.init(characterSet:"default",collation:nil,convert:false),.init(characterSet:"utf8mb4",collation:"utf8mb4_bin",convert:false)),
            (.init(characterSet:"latin1",collation:"default",convert:false),.init(characterSet:"utf8mb4",collation:"utf8mb4_bin",convert:false)),
            (.init(characterSet:"default",collation:"latin1_bin",convert:false),.init(characterSet:nil,collation:"latin1_bin",convert:false)),
            (.init(characterSet:"default",collation:nil,convert:true),.init(characterSet:"latin1",collation:"latin1_bin",convert:true)),
            (.init(characterSet:"utf8mb4",collation:"default",convert:true),.init(characterSet:"utf8mb4",collation:nil,convert:true)),
            (.init(characterSet:"default",collation:"latin1_swedish_ci",convert:true),.init(characterSet:"latin1",collation:"latin1_swedish_ci",convert:true))
        ]
        for (input,expected) in cases { XCTAssertEqual(input.resolvingDefaults(table:table,session:session),expected) }
    }
    func testDefaultTranslationEditsOnlyParsedTableClauses() throws {
        let sql=Data("ALTER TABLE t COLLATE latin1_bin, CHARACTER SET DEFAULT, ADD v VARCHAR(20) CHARACTER SET latin1 DEFAULT 'DEFAULT café' COMMENT 'COLLATE DEFAULT'".utf8)
        var parser=try DDLParser(sql,database:"poc")
        _ = try parser.parse()
        try parser.translateTableEncodingDefaults(final:.init(characterSet:"utf8mb4",collation:"utf8mb4_bin"),conversion:nil)
        XCTAssertEqual(parser.translatedSQL(sql),"ALTER TABLE t DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, ADD v VARCHAR(20) CHARACTER SET latin1 DEFAULT 'DEFAULT café' COMMENT 'COLLATE DEFAULT'")
        let convert=Data("ALTER TABLE t CONVERT TO CHARACTER SET DEFAULT, DEFAULT COLLATE latin1_bin".utf8)
        var parser2=try DDLParser(convert,database:"poc")
        _ = try parser2.parse()
        XCTAssertThrowsError(try parser2.translateTableEncodingDefaults(final:.init(characterSet:"latin1",collation:"latin1_bin"),conversion:nil))
        try parser2.translateTableEncodingDefaults(final:.init(characterSet:"latin1",collation:"latin1_bin"),conversion:.init(characterSet:"utf8mb4",collation:"utf8mb4_bin"))
        XCTAssertEqual(parser2.translatedSQL(convert),"ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT CHARACTER SET latin1 COLLATE latin1_bin")
    }

}
