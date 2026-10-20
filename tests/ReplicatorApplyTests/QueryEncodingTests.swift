import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class QueryEncodingTests: XCTestCase {
    func latin1(_ data: Data, _ identifier: Bool) -> DDLDecodedText {
        let text = String(String.UnicodeScalarView(data.map { UnicodeScalar(UInt32($0))! }))
        return .init(text: text, bytes: identifier ? nil : data)
    }
    func testRawTokenRangesAndLiteralBytesSurviveCompatibilityEdits() throws {
        let bytes =
            Data("CREATE TABLE `".utf8) + Data([0xe9]) + Data("`(id INT PRIMARY KEY,b VARBINARY(2) DEFAULT '".utf8)
            + Data([0xe9]) + Data("') DEFAULT CHARSET=utf8mb4".utf8)
        let tokens = try DDLTokens.lex(bytes, characterSet: "latin1", decode: latin1)
        var parser = try DDLParser(Data(), database: "poc")
        parser.tokens = tokens
        parser.compatibility.collations = ["utf8mb4_0900_ai_ci": "utf8mb4_bin"]
        guard case .create(let table, _) = try parser.parse() else { return XCTFail("CREATE expected") }
        XCTAssertEqual(table.table, "é")
        XCTAssertEqual(table.columns[1].binaryDefaultBytes, Data([0xe9]))
        XCTAssertEqual(parser.translatedBytes(bytes), bytes + Data(" COLLATE utf8mb4_bin".utf8))
        XCTAssertEqual(bytes.subdata(in: tokens[2].range!), Data([0x60, 0xe9, 0x60]))
    }
    func testMultibyteTrailingBackslashAndBacktickAreNotSyntax() throws {
        for charset in ["sjis", "cp932", "big5", "gbk", "gb18030"] {
            let lead: UInt8 = charset == "big5" ? 0xa1 : 0x95
            let bytes =
                Data("SELECT '".utf8) + Data([lead, 0x5c]) + Data("',`".utf8) + Data([lead, 0x60]) + Data("`".utf8)
            var converted: [Data] = []
            let tokens = try DDLTokens.lex(bytes, characterSet: charset) { data, identifier in
                if data.contains(lead) {
                    converted.append(data)
                    return .init(text: "中", bytes: identifier ? nil : data)
                }
                return .init(text: String(decoding: data, as: UTF8.self), bytes: nil)
            }
            XCTAssertEqual(tokens.count, 4, charset)
            XCTAssertEqual(converted, [Data([lead, 0x5c]), Data([lead, 0x60])], charset)
            XCTAssertEqual(tokens[1].literalBytes, Data([lead, 0x5c]), charset)
        }
        XCTAssertEqual(DDLClientEncoding.characterWidth([0x81, 0x30, 0x81, 0x30], at: 0, charset: "gb18030"), 4)
        XCTAssertEqual(DDLClientEncoding.characterWidth([0x81, 0x30, 0x81], at: 0, charset: "gb18030"), 1)
    }
    func testLoggedModeAndFilterUseTheSameDecodedTokens() throws {
        let bytes = Data("CREATE TABLE poc.`".utf8) + Data([0xe9]) + Data("`(v VARCHAR(10) DEFAULT '\\n')".utf8)
        let query = QueryControl(database: "poc", sql: bytes, errorCode: 0, statusVariables: Data())
        let tokens = try DDLTokens.lex(bytes, sqlMode: 1 << 20, characterSet: "latin1", decode: latin1)
        XCTAssertEqual(tokens.first(where: { $0.literal != nil })?.literal, "\\n")
        XCTAssertTrue(try TableFilter(["poc.é"]).ignores(query, tokens: tokens))
        XCTAssertFalse(try TableFilter(["poc.e"]).ignores(query, tokens: tokens))
        let escaped = try DDLTokens.lex(bytes, characterSet: "latin1", decode: latin1)
        XCTAssertEqual(escaped.first(where: { $0.literal != nil })?.literal, "\n")
    }
    func testUTF8LookingLatin1BytesAreNotNormalized() throws {
        let tokens = try DDLTokens.lex(Data([0x60, 0xc3, 0xa9, 0x60]), characterSet: "latin1", decode: latin1)
        XCTAssertEqual(tokens[0].text, "Ã©")
        XCTAssertNotEqual(tokens[0].text, "é")
    }
}
