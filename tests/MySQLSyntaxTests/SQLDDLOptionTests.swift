import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLDDLOptionTests: XCTestCase {
    func testOptionsAndConsumedRanges() throws {
        let cases: [(String, SQLDDLOption)] = [
            ("USING BTREE", .indexType("BTREE")), ("TYPE HASH", .indexType("HASH")),
            ("USING RTREE", .indexType("RTREE")),
            ("KEY_BLOCK_SIZE=4", .keyBlockSize(4)), ("KEY_BLOCK_SIZE 0", .keyBlockSize(0)),
            ("COMMENT 'a''b'", .comment("a'b")), ("WITH PARSER `ngram`", .parser("ngram")),
            ("WITH PARSER ngram", .parser("ngram")),
            ("ALGORITHM=INSTANT", .algorithm("INSTANT")), ("ALGORITHM COPY", .algorithm("COPY")),
            ("LOCK=NONE", .lock("NONE")), ("COLUMN_FORMAT FIXED", .columnFormat("FIXED")),
            ("STORAGE DISK", .storage("DISK")),
        ]
        for (sql, expected) in cases {
            let tokens = try SQLLexer.lex(Data(("prefix " + sql + " tail").utf8))
            var cursor = 1
            XCTAssertEqual(try SQLDDLOption.parseNext(tokens, index: &cursor), expected, sql)
            XCTAssertEqual(tokens[cursor].text, "tail")
        }
    }
    func testUnknownAndEmptyInputDoNotConsume() throws {
        for sql in ["", "ADD x INT", "`COMMENT` 'a'"] {
            let tokens = try SQLLexer.lex(Data(sql.utf8))
            var cursor = 0
            XCTAssertNil(try SQLDDLOption.parseNext(tokens, index: &cursor))
            XCTAssertEqual(cursor, 0)
        }
    }
    func testMalformedOptionsHaveNoPartialConsumption() throws {
        for sql in [
            "USING", "USING TREE", "TYPE 'BTREE'", "KEY_BLOCK_SIZE -1", "KEY_BLOCK_SIZE '2'", "KEY_BLOCK_SIZE `2`",
            "KEY_BLOCK_SIZE 18446744073709551616", "COMMENT a", "COMMENT", "WITH", "WITH OTHER x", "WITH PARSER",
            "WITH PARSER 'x'", "WITH PARSER 3", "ALGORITHM=OTHER", "LOCK READ", "COLUMN_FORMAT OTHER", "STORAGE OTHER",
        ] {
            let tokens = try SQLLexer.lex(Data(sql.utf8))
            var cursor = 0
            XCTAssertThrowsError(try SQLDDLOption.parseNext(tokens, index: &cursor), sql) {
                XCTAssertEqual(($0 as? SQLSyntaxError)?.range, tokens.first?.range)
            }
            XCTAssertEqual(cursor, 0)
        }
    }
}
