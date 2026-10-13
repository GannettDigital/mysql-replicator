import XCTest
import Foundation
@testable import ReplicatorCodec

final class BitValueTests: XCTestCase, BinlogFixtures {
    func fixture(_ metadata: [UInt8], interpretation: ColumnInterpretation = .unsigned) throws -> (BinlogDecoder,UInt64) {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4)
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,16,2])+Data(metadata)+Data([1]),at:at)
        let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let identity=try decoder.decode(map,at:at)
        XCTAssertEqual(identity.wireColumns?.first?.interpretation,.unsigned)
        XCTAssertEqual(identity.wireColumns?.first?.metadata,Data(metadata))
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[interpretation]))
        return (decoder,at+UInt64(map.count))
    }
    func testPackedBitWidthsAndRowOperations() throws {
        for width in [1,7,8,9,63,64] {
            let maximum = UInt64.max >> (64-width)
            // Deliberately asymmetric bytes detect a mistaken little-endian read.
            let pattern = UInt64(0x0123456789abcdef) & maximum
            let values:[UInt64?]=[0,maximum,UInt64(1) << (width-1),pattern,nil]
            func image(_ n:UInt64?) -> Data {
                guard let n else { return Data([1]) }
                let count=(width+7)/8
                return Data([0])+Data((0..<count).reversed().map { UInt8(truncatingIfNeeded:n >> ($0*8)) })
            }
            for op:UInt8 in [30,31,32] {
                let (decoder,at)=try fixture([UInt8(width%8),UInt8(width/8)])
                var payload=Data([123,0,0,0,0,0,1,0,2,0,1,1])
                if op == 31 { payload.append(1) }
                for value in values { payload.append(image(value)); if op == 31 { payload.append(image(0)) } }
                let decoded=try decoder.decode(event(op,payload,at:at),at:at)
                XCTAssertEqual(decoded.rows.count,values.count)
                for (row,value) in zip(decoded.rows,values) {
                    let expected:[DecodedValue]=[value.map(DecodedValue.unsigned) ?? .null]
                    XCTAssertEqual(op == 30 ? row.after : row.before,expected)
                    if op == 31 { XCTAssertEqual(row.after,[.unsigned(0)]) }
                }
            }
        }
    }
    func testBitMetadataPaddingAndTruncationRefusals() throws {
        for metadata:[UInt8] in [[0,0],[8,0],[1,8],[0,9],[255,255]] {
            XCTAssertThrowsError(try fixture(metadata))
        }
        XCTAssertThrowsError(try fixture([1,1],interpretation:.signed))
        for bytes in [Data([0,0x80,0]),Data([0,1])] {
            let (decoder,at)=try fixture([1,1])
            failure(2) { _ = try decoder.decode(event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1])+bytes,at:at),at:at) }
        }
    }
    func testBitDoesNotConsumeSignednessOrCharsetMetadata() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4),decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        // BIT(9), unsigned TINYINT, VARCHAR(10). Only TINYINT consumes signedness.
        let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,3,16,1,15,4,1,1,40,0,7,1,1,128,2,1,46])
        let decoded=try decoder.decode(event(19,body,at:at),at:at)
        XCTAssertEqual(decoded.wireColumns?.map(\.interpretation),[.unsigned,.unsigned,.utf8])
        XCTAssertEqual(decoded.wireColumns?.map(\.isUnsigned),[nil,true,nil])
        XCTAssertEqual(decoded.wireColumns?.last?.collation,46)
    }
}
