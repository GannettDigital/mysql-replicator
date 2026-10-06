import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class DDLDiagnosticsTests: XCTestCase {
    func testFailureContextPreservesDistinctLoggedIDsAndRoundTrips() throws {
        // Q_SQL_MODE, Q_CHARSET(client, connection, server), Q_CHARSET_DATABASE,
        // Q_DEFAULT_COLLATION_FOR_UTF8MB4. Deliberately use distinct values.
        let status=Data([1,0,0,0,0,0,0,0,0,4,45,0,224,0,255,0,8,46,0,18,45,0])
        let query=QueryControl(database:"foobar",sql:Data("CREATE DATABASE foobar".utf8),errorCode:0,statusVariables:status)
        let diagnostic=TargetFailureDiagnostic(reason:"unsupported",statement:.init(),rows:[],ddlGTID:"sid:10",ddlSQL:"CREATE DATABASE foobar",ddlContext:DDLQueryContextDiagnostic(query:query))
        let decoded=try JSONDecoder().decode(TargetFailureDiagnostic.self,from:JSONEncoder().encode(diagnostic))
        let context=try XCTUnwrap(decoded.ddlContext)
        XCTAssertEqual(context.database,"foobar")
        XCTAssertEqual(context.clientCharsetID,45)
        XCTAssertEqual(context.connectionCollationID,224)
        XCTAssertEqual(context.serverCollationID,255)
        XCTAssertEqual(context.serverCollationName,"utf8mb4_0900_ai_ci")
        XCTAssertEqual(context.databaseCollationID,46)
        XCTAssertEqual(context.defaultUTF8MB4CollationID,45)
        XCTAssertEqual(decoded.statement.phase,.notIssued)
    }

    func testUnknownAndMalformedContextDoNotInventNamesOrHideOriginalFailure() throws {
        let status=Data([1,0,0,0,0,0,0,0,0,4,45,0,224,0,255,255])
        let query=QueryControl(database:nil,sql:Data(),errorCode:0,statusVariables:status)
        let context=try XCTUnwrap(DDLQueryContextDiagnostic(query:query))
        XCTAssertEqual(context.serverCollationID,65535)
        XCTAssertNil(context.serverCollationName)
        XCTAssertNil(context.databaseCollationID)
        XCTAssertEqual(DDLQueryContextDiagnostic.collation(65535),"ID 65535")
        XCTAssertNil(DDLQueryContextDiagnostic(query:QueryControl(database:nil,sql:Data(),errorCode:0,statusVariables:Data([255]))))
        let old=Data(#"{"reason":"old failure","statement":{"phase":"notIssued"},"rows":[],"ddlSQL":"CREATE DATABASE foobar"}"#.utf8)
        let decoded=try JSONDecoder().decode(TargetFailureDiagnostic.self,from:old)
        XCTAssertNil(decoded.ddlContext)
        XCTAssertEqual(decoded.reason,"old failure")
    }
}
