import XCTest
import Foundation
@testable import ReplicatorCodec

final class LargeValueTests: XCTestCase, BinlogFixtures {
    func testBlobAcrossOldLimitAndConfiguredEventBoundary() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4)
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,252,1,4,1]),at:at)
        let probe=try BinlogDecoder(); _ = try probe.decode(fde,at:4)
        let identity=try probe.decode(map,at:at)
        let history=TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.binary])
        let rowAt=at+UInt64(map.count)
        for length in [1024*1024-1,1024*1024,1024*1024+1] {
            let value=Data(repeating:0xa5,count:length)
            let row=event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1,0])+le(UInt32(length))+value,at:rowAt)
            for limit in [row.count-1,row.count] {
                let decoder=try BinlogDecoder(maximumEventBytes:UInt32(limit))
                _ = try decoder.decode(fde,at:4); _ = try decoder.decode(map,at:at,schema:history)
                if limit < row.count { failure(5) { _ = try decoder.decode(row,at:rowAt) } }
                else { XCTAssertEqual(try decoder.decode(row,at:rowAt).rows.first?.after,[.binary(value)]) }
            }
        }
    }
    func testLargeDeclaredLengthCannotReadPastEvent() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4), decoder=try BinlogDecoder()
        _ = try decoder.decode(fde,at:4)
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,252,1,4,1]),at:at)
        let identity=try decoder.decode(map,at:at)
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.binary]))
        let rowAt=at+UInt64(map.count)
        let row=event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1,0])+le(UInt32.max),at:rowAt)
        XCTAssertThrowsError(try decoder.decode(row,at:rowAt))
    }
}
