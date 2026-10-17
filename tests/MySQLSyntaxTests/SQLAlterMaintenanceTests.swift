import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLAlterMaintenanceTests: XCTestCase {
  func testCompleteMaintenanceClauses() throws {
    for (sql, expected) in [
      ("FORCE", SQLAlterMaintenance.force), ("enable /* kept */ keys", .enableKeys),
      ("DISABLE KEYS", .disableKeys),
    ] {
      XCTAssertEqual(try SQLAlterMaintenance.parse(SQLLexer.lex(Data(sql.utf8))), expected)
    }
  }
  func testInvalidOrIncompleteClausesHaveNoRecovery() throws {
    for sql in [
      "", "ENABLE", "DISABLE KEY", "FORCE TABLE", "`FORCE`", "FORCE; DROP TABLE t", "ENABLE 'KEYS'",
    ] {
      let tokens = try SQLLexer.lex(Data(sql.utf8))
      XCTAssertThrowsError(try SQLAlterMaintenance.parse(tokens)) { error in
        XCTAssertEqual((error as? SQLSyntaxError)?.range, tokens.first?.range)
      }
    }
  }
}
