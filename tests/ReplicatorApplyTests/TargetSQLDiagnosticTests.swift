import XCTest

@testable import MySQLNIO
@testable import ReplicatorApply

final class TargetSQLDiagnosticTests: XCTestCase {
    func testPreparationErrorRoundTripDoesNotChangeMutationOutcome() throws {
        let sql = "SET SESSION explicit_defaults_for_timestamp=1"
        let message = "Access denied; you need (at least one of) the SUPER privilege(s) for this operation"
        let error = TargetSQLDiagnostic.applyError(
            .server(
                .init(
                    errorCode: .SPECIFIC_ACCESS_DENIED_ERROR, sqlStateMarker: "#", sqlState: "42000",
                    errorMessage: message)),
            sql: sql)
        XCTAssertEqual(error.code, .targetSQL)
        XCTAssertEqual(error.mysqlErrorNumber, 1227)
        XCTAssertTrue(error.description.contains(message))
        let diagnostic = TargetFailureDiagnostic(
            reason: error.description, statement: .init(), rows: [], ddlGTID: "sid:1",
            ddlSQL: "CREATE TABLE new_table LIKE existing_table", targetSQL: error.targetSQL)
        let restored = try JSONDecoder().decode(TargetFailureDiagnostic.self, from: JSONEncoder().encode(diagnostic))
        XCTAssertEqual(restored.targetSQL?.sql, sql)
        XCTAssertEqual(restored.targetSQL?.serverMessage, message)
        XCTAssertEqual(restored.targetSQL?.sqlState, "42000")
        XCTAssertEqual(restored.statement.phase, .notIssued)
        XCTAssertNil(restored.statement.sql)
    }

    func testDuplicateAndSyntaxMessagesSurviveDriverSpecialCases() {
        let duplicate = TargetSQLDiagnostic.applyError(
            .duplicateEntry("Duplicate entry"), sql: "INSERT INTO t VALUES(?)")
        XCTAssertEqual(duplicate.code, .duplicateKey)
        XCTAssertEqual(duplicate.mysqlErrorNumber, 1062)
        XCTAssertEqual(duplicate.targetSQL?.sql, "INSERT INTO t VALUES(?)")
        let syntax = TargetSQLDiagnostic.applyError(.invalidSyntax("Syntax error"), sql: "invalid SQL")
        XCTAssertEqual(syntax.targetSQL?.serverMessage, "Syntax error")
        XCTAssertEqual(syntax.mysqlErrorNumber, 1064)
    }
}
