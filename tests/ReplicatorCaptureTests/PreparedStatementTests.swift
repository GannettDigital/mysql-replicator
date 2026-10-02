import XCTest
import NIOCore
@testable import MySQLNIO
@testable import ReplicatorCapture

final class PreparedStatementTests: XCTestCase {
    func packet(_ bytes: [UInt8]) -> MySQLPacket { .init(payload:ByteBuffer(bytes:bytes)) }
    func command(_ cache: MySQLPreparedStatementCache, sql: String = "INSERT INTO t VALUES (1)",
                 binds: [MySQLData] = [], metadata: @escaping (MySQLQueryMetadata) throws -> Void = { _ in }) -> MySQLQueryCommand {
        .init(sql:sql,binds:binds,onRow:{_ in},onMetadata:metadata,logger:.init(label:"test"),cache:cache)
    }
    func prepared(_ command: MySQLQueryCommand, id: UInt8) throws {
        var response = packet([0,id,0,0,0,0,0,0,0,0,0,0])
        let execute = try command.handle(packet:&response,capabilities:[])
        XCTAssertEqual(execute.response.first?.payload.getInteger(at:0,as:UInt8.self),0x17)
    }
    func finish(_ command: MySQLQueryCommand) throws -> MySQLCommandState {
        var response = packet([0,1,0])
        return try command.handle(packet:&response,capabilities:[])
    }
    func testPrepareOnceThenExecuteWithFreshMetadata() throws {
        let cache = MySQLPreparedStatementCache()
        var affected: [UInt64] = []
        let first = command(cache,metadata:{affected.append($0.affectedRows)})
        XCTAssertEqual(try first.activate(capabilities:[]).response[0].payload.getInteger(at:0,as:UInt8.self),0x16)
        try prepared(first,id:7)
        XCTAssertTrue(try finish(first).response.isEmpty)
        XCTAssertEqual(cache.entries.count,1)
        let second = command(cache,metadata:{affected.append($0.affectedRows)})
        let execute = try second.activate(capabilities:[]).response[0].payload
        XCTAssertEqual(execute.getInteger(at:0,as:UInt8.self),0x17)
        XCTAssertEqual(execute.getInteger(at:1,endianness:.little,as:UInt32.self),7)
        XCTAssertTrue(try finish(second).done)
        XCTAssertEqual(affected,[1,1])
    }
    func testCachedBinaryBindingsAreNotReusedFromPreviousExecution() throws {
        let cache = MySQLPreparedStatementCache()
        cache.entries["SELECT ?"] = .init(id:9,parameters:1)
        let first = command(cache,sql:"SELECT ?",binds:[.init(string:"first")])
        let second = command(cache,sql:"SELECT ?",binds:[.init(string:"second")])
        let a = try first.activate(capabilities:[]).response[0].payload
        let b = try second.activate(capabilities:[]).response[0].payload
        XCTAssertNotEqual(a,b)
        XCTAssertTrue(Array(b.readableBytesView).suffix(6).elementsEqual(Array("second".utf8)))
        XCTAssertThrowsError(try command(cache,sql:"SELECT ?").activate(capabilities:[]))
    }
    func testErrorClosesAndEvictsWithoutRetry() throws {
        let cache = MySQLPreparedStatementCache()
        let sql = "INSERT INTO t VALUES (1)"
        cache.entries[sql] = .init(id:7,parameters:0)
        let query = command(cache)
        _ = try query.activate(capabilities:[])
        var error = packet([0xff,0x26,0x04] + Array("duplicate".utf8)) // 1062
        let result = try query.handle(packet:&error,capabilities:[])
        XCTAssertTrue(result.done)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.response.count,1)
        XCTAssertEqual(result.response[0].payload.getInteger(at:0,as:UInt8.self),0x19)
        XCTAssertTrue(cache.entries.isEmpty)
    }
    func testCapacityFallsBackToCloseAndCachesAreIsolated() throws {
        let cache = MySQLPreparedStatementCache()
        for i in 0..<cache.capacity { cache.entries[String(i)] = .init(id:UInt32(i),parameters:0) }
        let query = command(cache)
        _ = try query.activate(capabilities:[]); try prepared(query,id:250)
        let result = try finish(query)
        XCTAssertEqual(result.response[0].payload.getInteger(at:0,as:UInt8.self),0x19)
        XCTAssertEqual(cache.entries.count,cache.capacity)
        XCTAssertTrue(MySQLPreparedStatementCache().entries.isEmpty)
    }
    func testInvalidationRunsAfterEarlierCommandsPopulateCache() throws {
        let cache = MySQLPreparedStatementCache()
        let barrier = MySQLStatementCacheBarrier(cache:cache)
        // A query already ahead of the barrier finishes after it is constructed.
        cache.entries["SELECT 1"] = .init(id:7,parameters:0)
        XCTAssertTrue(try barrier.activate(capabilities:[]).done)
        XCTAssertEqual(barrier.ids,[7])
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertEqual(try command(cache,sql:"SELECT 1").activate(capabilities:[]).response[0].payload.getInteger(at:0,as:UInt8.self),0x16)
    }
    func testIdleCallbackDoesNotHoldQueueMutexAndFailurePropagates() throws {
        let queue = PacketQueue(byteLimit:10)
        var reads = 0
        let value = try queue.next(timeout:1,cancellation:.init(),requestRead:{reads += 1},onIdle:{try queue.push(Data([1]))})
        XCTAssertEqual(value,Data([1])); XCTAssertEqual(reads,0)
        XCTAssertThrowsError(try queue.next(timeout:1,cancellation:.init(),requestRead:{},onIdle:{throw CaptureError("unlock failed")})) {
            XCTAssertEqual(String(describing:$0),"unlock failed")
        }
    }
}
