import Foundation
import XCTest
@testable import MySQLSyntax

final class SQLExecutableCommentTests:XCTestCase {
  func view(_ sql:String,_ version:Int = 50742,_ mode:UInt64 = 0) throws -> String {
    String(decoding:try SQLExecutableComments.parsingView(Data(sql.utf8),serverVersion:version,sqlMode:mode),as:UTF8.self)
  }
  func testTargetGateAndOriginalOffsets() throws {
    let sql="ALTER TABLE t ADD n INT /*!80400 , ADD newer INT */"
    let low=try view(sql),high=try view(sql,80408)
    XCTAssertEqual(low.utf8.count,sql.utf8.count)
    XCTAssertFalse(low.contains("newer"));XCTAssertTrue(high.contains(", ADD newer INT"))
    let original=Data(sql.utf8),tokens=try SQLLexer.lex(Data(high.utf8))
    for token in tokens {XCTAssertEqual(String(decoding:original[token.range!],as:UTF8.self),token.text)}
    XCTAssertEqual(try view(high,80408),high)
    XCTAssertEqual(try view("/*!50742 CREATE TABLE t(id INT) */").trimmingCharacters(in:.whitespaces),"CREATE TABLE t(id INT)")
    XCTAssertEqual(try view("/*!50743 CREATE TABLE t(id INT) */").trimmingCharacters(in:.whitespaces),"")
  }
  func testNativeFiveAndSixDigitFormats() throws {
    XCTAssertEqual(try view("/*!050700 + 1 */").trimmingCharacters(in:.whitespaces),"0 + 1")
    XCTAssertEqual(try view("/*!050700 + 1 */",80408).trimmingCharacters(in:.whitespaces),"+ 1")
    XCTAssertEqual(try view("/*!050700+1 */",80408).trimmingCharacters(in:.whitespaces),"0+1")
    XCTAssertEqual(try view("/*!42 */").trimmingCharacters(in:.whitespaces),"42")
    XCTAssertEqual(try view("/*! CREATE TABLE t(id INT) */").trimmingCharacters(in:.whitespaces),"CREATE TABLE t(id INT)")
  }
  func testOrdinaryCommentsAndQuotedTextStayInactive() throws {
    for sql in ["/* 80400 ADD c INT */","/*+ hint */ SELECT 1","SELECT '/*!50700 keep */'","SELECT `/*!50700 name */`","-- /*!50700 keep */\nSELECT 1","# /*!50700 keep */\nSELECT 1"] {
      XCTAssertEqual(try view(sql),sql)
    }
    let sql="/*!50700 CREATE TABLE t(n VARCHAR(80) DEFAULT 'a''*/b',`a``b` INT) */"
    XCTAssertTrue(try view(sql).contains("DEFAULT 'a''*/b',`a``b`"))
    XCTAssertTrue(try view(#"/*!50700 SELECT 'a\'*/b' */"#).contains(#"'a\'*/b'"#))
    XCTAssertTrue(try view(#"/*!50700 SELECT 'a\' */"#,50742,1<<20).contains(#"'a\'"#))
    XCTAssertTrue(try view(#"/*!50700 SELECT "a\" */"#,50742,4).contains(#""a\""#))
  }
  func testNestedAndInactiveCommentScanning() throws {
    XCTAssertTrue(try view("/*!50700 CREATE /* note */ TABLE t(id INT) */").contains("/* note */ TABLE"))
    XCTAssertTrue(try view("/*!50700 CREATE /*!50700 TABLE */ t(id INT) */").contains("TABLE"))
    XCTAssertEqual(try view("/*!99999 ignored /* inner */ tail */ SELECT 1").trimmingCharacters(in:.whitespaces),"SELECT 1")
    // Native inactive comments do not recognize quotes.
    XCTAssertThrowsError(try view("/*!99999 '*/' SELECT 1"))
  }
  func testClientCharacterBoundaries() throws {
    let bytes=Data("/*!50700 SELECT '".utf8)+Data([0x81,0x5c])+Data("' */".utf8)
    let result=try SQLExecutableComments.parsingView(bytes,serverVersion:50742,characterSet:"sjis")
    XCTAssertEqual(result.count,bytes.count)
    XCTAssertTrue(result.range(of:Data([0x81,0x5c])) != nil)
    let identifier=Data("/*!50700 SELECT ".utf8)+Data([0x81,0x60])+Data(" */".utf8)
    XCTAssertNoThrow(try SQLExecutableComments.parsingView(identifier,serverVersion:50742,characterSet:"sjis"))
  }
  func testMalformedInputAndLimits() throws {
    for sql in ["/*!50700 SELECT 1","/*!99999 missing","/*!99999 /* nested */","/*!50700 SELECT 'missing */","/*!50700 /* missing","/*!50700 SELECT 'escape\\"] {
      XCTAssertThrowsError(try view(sql),sql)
    }
    XCTAssertThrowsError(try view(String(repeating:" ",count:65537)))
    XCTAssertThrowsError(try view(String(repeating:"/*! ",count:65)+String(repeating:" */",count:65)))
    XCTAssertEqual(try view("CREATE TABLE t(id INT)"),"CREATE TABLE t(id INT)")
  }
  func testCaptureKeywordDoesNotNormalizeControls() {
    for (sql,word) in [("CREATE TABLE t(id INT)","CREATE"),(" /*!50700 CREATE TABLE t(id INT) */","CREATE"),("/*!050700 CREATE TABLE t(id INT) */","CREATE"),("/*!50700 */ /* note */ ALTER TABLE t ADD n INT","ALTER"),("-- hi\n# next\n/*! COMMIT */","COMMIT"),("/* 99999 ignored */ SELECT 1","SELECT")] {
      XCTAssertEqual(SQLExecutableComments.leadingKeyword(Data(sql.utf8)),word)
    }
    for sql in [""," ","/* unfinished","/*!50700 */","/*!50700 1 */",";","# nothing"] {XCTAssertNil(SQLExecutableComments.leadingKeyword(Data(sql.utf8)))}
  }
}
