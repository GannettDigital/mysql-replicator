import Foundation
import MySQLNIO
import ReplicatorCodec
import XCTest

@testable import ReplicatorApply

final class DiscoveryReadsTests: XCTestCase {
    let sql = "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=?"
    let table = TableName(database: "db", table: "t")
    func testNestedDiscoveryReusesReadsButNextScopeReadsAgain() throws {
        let cache = DiscoveryReads()
        let timings = StageTimings()
        var calls = 0
        func read(_ name: String = "t") -> DiscoveryReads.Result {
            cache.read(sql, binds: [.init(string: "db"), .init(string: name)], textProtocol: false, timings: timings) {
                calls += 1
                return ([], nil)
            }
        }
        cache.scope(table) {
            _ = read()
            cache.scope(TableName(database: "db", table: "child")) {
                _ = read()
                _ = read("other")
            }
            XCTAssertEqual(cache.table?.table, "t")
            _ = read()
        }
        XCTAssertNil(cache.table)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(timings.snapshot["target.metadata.cache_hit"]?.count, 2)
        cache.scope(table) { _ = read() }
        _ = read()
        _ = read()
        XCTAssertEqual(calls, 5)
    }
    func testTextAndPreparedReadsUseSeparateCacheEntries() {
        let cache = DiscoveryReads()
        let timings = StageTimings()
        var calls = 0
        cache.scope(table) {
            for textProtocol in [true, false, true, false] {
                let result = cache.read(sql, binds: [], textProtocol: textProtocol, timings: timings) {
                    calls += 1
                    return ([], textProtocol ? 1 : 2)
                }
                XCTAssertEqual(result.1, textProtocol ? 1 : 2)
            }
        }
        XCTAssertEqual(calls, 2)
    }
    func testFailureClearsScopeAndDoesNotCacheErrors() {
        let cache = DiscoveryReads()
        let timings = StageTimings()
        var calls = 0
        func read() throws -> DiscoveryReads.Result {
            try cache.read(sql, binds: [], textProtocol: false, timings: timings) {
                calls += 1
                throw ApplyError("fixture failure")
            }
        }
        XCTAssertThrowsError(try cache.scope(table) { try read() })
        XCTAssertNil(cache.table)
        XCTAssertThrowsError(try cache.scope(table) { try read() })
        XCTAssertEqual(calls, 2)
        XCTAssertNil(timings.snapshot["target.metadata.cache_hit"])
    }
    func testCapacityBypassesCachingAndSessionQueriesAreNeverReused() {
        let cache = DiscoveryReads(maximumBytes: 1)
        let timings = StageTimings()
        var calls = 0
        cache.scope(table) {
            for _ in 0..<2 {
                _ = cache.read(sql, binds: [], textProtocol: false, timings: timings) {
                    calls += 1
                    return ([], nil)
                }
            }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertNil(DiscoveryReads.Key("SELECT @@SESSION.GTID_NEXT", binds: [], textProtocol: false))
        XCTAssertNil(DiscoveryReads.Key("SET SESSION sql_mode=''", binds: [], textProtocol: false))
        XCTAssertNil(DiscoveryReads.Key(sql, binds: [.init(int: 1)], textProtocol: false))
    }
    func testIdentifierKeysPreserveBytesAndParameterBoundaries() {
        func key(_ values: [String]) -> DiscoveryReads.Key? {
            .init(sql, binds: values.map { .init(string: $0) }, textProtocol: false)
        }
        XCTAssertNotEqual(key(["é"]), key(["e\u{301}"]))
        XCTAssertNotEqual(key(["db", "t"]), key(["DB", "t"]))
        XCTAssertNotEqual(key(["a", "bc"]), key(["ab", "c"]))
    }
}
