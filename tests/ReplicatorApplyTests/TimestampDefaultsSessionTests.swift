import XCTest

@testable import ReplicatorApply

final class TimestampDefaultsSessionTests: XCTestCase {
    func testMatchingDefaultDoesNotWriteAndIsCachedPerConnection() throws {
        var reads = 0
        let read = {
            reads += 1
            return "1" as String?
        }
        let enable = { XCTFail("must not require a privileged SET") }
        let session = TimestampDefaultsSession()
        try session.prepare(read: read, enable: enable)
        try session.prepare(read: read, enable: enable)
        XCTAssertEqual(reads, 1)
        try TimestampDefaultsSession().prepare(read: read, enable: enable)
        XCTAssertEqual(reads, 2)
    }

    func testDisabledDefaultIsEnabledOnce() throws {
        var writes = 0
        let session = TimestampDefaultsSession()
        try session.prepare(read: { "OFF" }, enable: { writes += 1 })
        try session.prepare(
            read: {
                XCTFail("already prepared")
                return nil
            }, enable: { writes += 1 })
        XCTAssertEqual(writes, 1)
    }

    func testFailedSetKeepsDetailsAndDoesNotMarkSessionReady() throws {
        let detail = TargetSQLDiagnostic(
            sql: "SET SESSION explicit_defaults_for_timestamp=1", mysqlErrorNumber: 1227,
            sqlState: "42000", serverMessage: "Access denied; SUPER privilege required")
        let session = TimestampDefaultsSession()
        XCTAssertThrowsError(
            try session.prepare(
                read: { "0" },
                enable: {
                    throw ApplyError(
                        "access denied", code: .targetSQL, mysqlErrorNumber: 1227, sqlState: "42000", targetSQL: detail)
                })
        ) { error in
            let failure = error as? ApplyError
            XCTAssertEqual(failure?.mysqlErrorNumber, 1227)
            XCTAssertEqual(failure?.code, .targetSQL)
            XCTAssertEqual(failure?.sqlState, "42000")
            XCTAssertEqual(failure?.targetSQL, detail)
            XCTAssertTrue(String(describing: error).contains("ask the DBA"))
        }
        var reads = 0
        try session.prepare(
            read: {
                reads += 1
                return "ON"
            }, enable: { XCTFail("unexpected SET") })
        XCTAssertEqual(reads, 1)
    }

    func testUnknownValueAndConnectionFailureDoNotHideCause() throws {
        let session = TimestampDefaultsSession()
        for value in [nil, "invalid"] as [String?] {
            XCTAssertThrowsError(try session.prepare(read: { value }, enable: { XCTFail("unknown value") }))
        }
        XCTAssertThrowsError(
            try session.prepare(
                read: { "0" },
                enable: {
                    throw TargetConnectionFailure(description: "test disconnect")
                })
        ) { XCTAssertTrue($0 is TargetConnectionFailure) }
    }
}
