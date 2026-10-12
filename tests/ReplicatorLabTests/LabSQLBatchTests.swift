import XCTest
@testable import ReplicatorLabCore

final class LabSQLBatchTests: XCTestCase {
    func testEmptyResultsAndExactWhitespace() throws {
        let batch = LabSQLBatch(queries: [
            .init(name: "empty", sql: "SELECT 1 WHERE FALSE"),
            .init(name: "columns", sql: "SELECT 'fixture'", preserveWhitespace: true),
            .init(name: "trimmed", sql: "SELECT 'fixture'")
        ])
        let raw = " \tNULL\t\0\nsecond row\t\n\n"
        let output = batch.marker(0) + "\n" + batch.marker(1) + "\n" + raw + "\n" +
            batch.marker(2) + "\n \tvalue\t \n" + batch.marker(3) + "\n"
        XCTAssertEqual(try batch.decode(output), ["empty": "", "columns": raw, "trimmed": "value"])
    }

    func testTruncatedReorderedAndExtraResultsFail() throws {
        let batch = LabSQLBatch(queries: [.init(name: "first", sql: "SELECT 1"), .init(name: "second", sql: "SELECT 2")])
        let valid = batch.marker(0) + "\n1\n" + batch.marker(1) + "\n2\n" + batch.marker(2) + "\n"
        XCTAssertEqual(try batch.decode(valid), ["first": "1", "second": "2"])
        for bad in [String(valid.dropLast()), valid + "extra\n", "extra\n" + valid,
                    valid.replacingOccurrences(of: batch.marker(1), with: "missing"),
                    valid.replacingOccurrences(of: "1\n", with: batch.marker(2) + "\n")] {
            XCTAssertThrowsError(try batch.decode(bad))
        }
    }

    func testDuplicateNamesFailAndEmptyBatchDecodes() throws {
        let batch = LabSQLBatch(queries: [.init(name: "a", sql: "SELECT 1"), .init(name: "a", sql: "SELECT 2")])
        XCTAssertThrowsError(try batch.decode(batch.marker(0) + "\n"))
        let empty = LabSQLBatch(queries: [])
        XCTAssertEqual(try empty.decode(empty.marker(0) + "\n"), [:])
    }
}
