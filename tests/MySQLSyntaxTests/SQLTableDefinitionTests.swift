import Foundation
import XCTest
@testable import MySQLSyntax

final class SQLTableDefinitionTests:XCTestCase {
  func testNestedDefinitionsAndQuotedNames() throws {
    let sql="CREATE TABLE `t` (`a` decimal(10,2) DEFAULT '),; CHECK',`PRIMARY` int,`b` int GENERATED ALWAYS AS ((`a`+1)) STORED,PRIMARY KEY (`PRIMARY`),CONSTRAINT `ck` CHECK (`a`>0)) ENGINE=InnoDB"
    let raw=Data(sql.utf8), columns=try SQLTableDefinition.columns(SQLLexer.lex(raw))
    XCTAssertEqual(columns.map(\.name),["a","PRIMARY","b"])
    XCTAssertEqual(String(decoding:raw[columns[0].definition],as:UTF8.self)," decimal(10,2) DEFAULT '),; CHECK'")
    XCTAssertEqual(String(decoding:raw[columns[2].definition],as:UTF8.self)," int GENERATED ALWAYS AS ((`a`+1)) STORED")
    XCTAssertEqual(try SQLTableDefinition.columns(SQLLexer.lex(Data("CREATE TEMPORARY TABLE t(a int)".utf8))).count,1)
  }
  func testMalformedInputAndMissingRanges() throws {
    for sql in ["ALTER TABLE t ADD a int","CREATE VIEW t AS SELECT 1","CREATE TABLE t LIKE q","CREATE TABLE t()","CREATE TABLE t(a)","CREATE TABLE t(a int,)","CREATE TABLE t(a int","CREATE TABLE t(a int;DROP TABLE q)","CREATE TABLE t(KEY(a))","CREATE TABLE t(a decimal(10,2)"] {
      XCTAssertThrowsError(try SQLTableDefinition.columns(SQLLexer.lex(Data(sql.utf8))),sql)
    }
    var tokens=try SQLLexer.lex(Data("CREATE TABLE t(a int)".utf8))
    tokens[4].range=nil
    XCTAssertThrowsError(try SQLTableDefinition.columns(tokens))
  }
}
