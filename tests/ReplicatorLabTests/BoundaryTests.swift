import XCTest

@testable import ReplicatorLabCore

final class BoundaryTests: XCTestCase {
    func testBothVersionsReadPositionThenGTIDsInOneBatch() throws {
        for command in ["SHOW MASTER STATUS", "SHOW BINARY LOG STATUS"] {
            var calls = 0
            let gtids = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:1-7:9,\nbbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb:blue:1-3"
            let boundary = try Boundary.read(statusCommand: command) { queries in
                calls += 1
                XCTAssertEqual(queries.map(\.name), ["position", "gtids"])
                XCTAssertEqual(queries.map(\.sql), [command, "SELECT @@GLOBAL.gtid_executed"])
                return ["gtids": gtids, "position": "binlog.000002\t12345678901\t\t\tolder-gtid-set"]
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(boundary.file, "binlog.000002")
            XCTAssertEqual(boundary.position, 12_345_678_901)
            XCTAssertEqual(boundary.gtids, gtids)
        }
    }

    func testEmptyGTIDsAndLargeOffsetsArePreserved() throws {
        let boundary = try Boundary.read(statusCommand: "SHOW MASTER STATUS") { _ in
            ["position": "binlog.000001\t18446744073709551615\t\t\t", "gtids": ""]
        }
        XCTAssertEqual(boundary.position, UInt64.max)
        XCTAssertEqual(boundary.gtids, "")
    }

    func testEveryCallReadsANewPosition() throws {
        var offset = 4
        var calls = 0
        func read() throws -> Boundary {
            try Boundary.read(statusCommand: "SHOW MASTER STATUS") { _ in
                calls += 1
                return ["position": "binlog.000001\t\(offset)\t\t\t", "gtids": ""]
            }
        }
        XCTAssertEqual(try read().position, 4)
        offset = 120
        XCTAssertEqual(try read().position, 120)
        XCTAssertEqual(calls, 2)
    }

    func testMissingAndExtraResultsFail() {
        for results in [
            [:], ["position": "binlog.000001\t4"], ["gtids": ""],
            ["position": "binlog.000001\t4", "gtids": "", "extra": ""],
        ] {
            XCTAssertThrowsError(try Boundary.read(statusCommand: "SHOW MASTER STATUS") { _ in results })
        }
    }

    func testInvalidPositionAndFilenameFail() {
        for status in [
            "", "binlog.000001", "binlog.000001\t", "binlog.000001\t-1", "binlog.000001\tNaN",
            "binlog.000001\t18446744073709551616", "../binlog.000001\t4", "binlog.name\t4",
        ] {
            XCTAssertThrowsError(
                try Boundary.read(statusCommand: "SHOW MASTER STATUS") { _ in ["position": status, "gtids": ""] })
        }
    }

    func testClientFailurePropagatesWithoutRetry() {
        var calls = 0
        XCTAssertThrowsError(
            try Boundary.read(statusCommand: "SHOW MASTER STATUS") { _ in
                calls += 1
                throw LabError("client failed")
            })
        XCTAssertEqual(calls, 1)
    }
}
