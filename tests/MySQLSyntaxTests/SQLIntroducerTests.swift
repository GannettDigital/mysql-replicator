import Foundation
import XCTest
@testable import MySQLSyntax

final class SQLIntroducerTests:XCTestCase {
    func testIntroducedByteLiterals() throws {
        for sql in ["_binary X'80ff'","_binary 0x80ff","_binary B'1000000011111111'"] {
            XCTAssertEqual(try SQLExpression.parse(SQLLexer.lex(Data(sql.utf8))),.introduced("_binary",.bytes(Data([0x80,0xff]))))
        }
        for sql in ["_binary X'bad'","_binary 1","_binary 0xGG"] {
            XCTAssertThrowsError(try SQLExpression.parse(SQLLexer.lex(Data(sql.utf8))))
        }
    }
    func testIntroducedLiteralKeepsInputBytes() throws {
        let tokens=try SQLLexer.lex(Data("_latin1 'é'".utf8)) { bytes,identifier in
            .init(text:identifier ? String(decoding:bytes,as:UTF8.self) : "é",bytes:identifier ? nil : Data([0xe9]))
        }
        XCTAssertEqual(tokens[1].literalBytes,Data([0xc3,0xa9]))
    }
    func testQuotedCommentDelimiterInMetadata() throws {
        let tokens=try SQLLexer.lex(Data("/*!50500 '*/','a\\n','it''s',`*/` */".utf8),nativeMetadata:true)
        XCTAssertEqual(tokens.filter {$0.literal != nil}.map(\.literal),["*/","a\n","it's"])
        XCTAssertEqual(tokens.last?.text,"*/")
        XCTAssertThrowsError(try SQLLexer.lex(Data("/*! 'unfinished */".utf8),nativeMetadata:true))
    }
    func testMetadataCommentsKeepDecoder() throws {
        var data=Data("/*!50500 '".utf8);data.append(0x80);data.append(Data("' */".utf8))
        let tokens=try SQLLexer.lex(data,nativeMetadata:true) { bytes,_ in .init(text:"raw",bytes:bytes) }
        XCTAssertEqual(tokens.count,1)
        XCTAssertEqual(tokens[0].literalBytes,Data([0x80]))
        XCTAssertEqual(tokens[0].range,9..<12)
    }
}
