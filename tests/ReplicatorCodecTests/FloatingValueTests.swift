import XCTest
import Foundation
@testable import ReplicatorCodec

final class FloatingValueTests: XCTestCase, BinlogFixtures {
    func fixture(_ code:UInt8,_ metadata:UInt8,kind:ColumnInterpretation) throws -> (BinlogDecoder,UInt64) {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4)
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,code,1,metadata,1]),at:at)
        let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let identity=try decoder.decode(map,at:at)
        XCTAssertEqual(identity.wireColumns?.first?.interpretation,code == 4 ? .float32 : .float64)
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[kind]))
        return (decoder,at+UInt64(map.count))
    }
    func testIEEEBitsSurviveAllRowOperations() throws {
        XCTAssertEqual(Codec.abiVersion,9)
        let singles:[UInt64]=[0,0x80000000,0x3dcccccd,0xbdcccccd,1,0x80000001,0x007fffff,0x00800000,0x7f7fffff,0xff7fffff,0x3f800001]
        let doubles:[UInt64]=[0,0x8000000000000000,0x3fb999999999999a,0xbfb999999999999a,1,0x8000000000000001,0x000fffffffffffff,0x0010000000000000,0x7fefffffffffffff,0xffefffffffffffff,0x3ff0000000000001]
        for (code,width,kind,values):(UInt8,UInt8,ColumnInterpretation,[UInt64]) in [(4,4,.float32,singles),(5,8,.float64,doubles)] {
            func image(_ value:UInt64) -> Data { Data([0])+Data(le(value).prefix(Int(width))) }
            for operation:UInt8 in [30,31,32] {
                let (decoder,at)=try fixture(code,width,kind:kind)
                var body=Data([123,0,0,0,0,0,1,0,2,0,1,1]); if operation == 31 { body.append(1) }
                for value in values { body.append(image(value)); if operation == 31 { body.append(image(0)) } }
                body.append(1); if operation == 31 { body.append(1) }
                let rows=try decoder.decode(event(operation,body,at:at),at:at).rows
                XCTAssertEqual(rows.count,values.count+1)
                for (row,bits) in zip(rows,values) {
                    let expected:DecodedValue=code == 4 ? .float32(UInt32(bits)) : .float64(bits)
                    XCTAssertEqual(operation == 30 ? row.after : row.before,[expected])
                    if operation == 31 { XCTAssertEqual(row.after,[code == 4 ? .float32(0) : .float64(0)]) }
                }
                XCTAssertEqual(operation == 30 ? rows.last?.after : rows.last?.before,[.null])
            }
        }
    }
    func testNonFiniteTruncatedAndWrongWidthValuesFail() throws {
        for (code,width,kind):(UInt8,UInt8,ColumnInterpretation) in [(4,4,.float32),(5,8,.float64)] {
            for wrong:UInt8 in [0,3,code == 4 ? 8 : 4,255] { XCTAssertThrowsError(try fixture(code,wrong,kind:kind)) }
            XCTAssertThrowsError(try fixture(code,width,kind:.decimal))
            let values:[UInt64]=code == 4 ? [0x7f800000,0xff800000,0x7fc00001] : [0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000001]
            for bits in values {
                let (decoder,at)=try fixture(code,width,kind:kind)
                failure(4) { _ = try decoder.decode(event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1,0])+Data(le(bits).prefix(Int(width))),at:at),at:at) }
            }
            let (decoder,at)=try fixture(code,width,kind:kind)
            failure(2) { _ = try decoder.decode(event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1,0])+Data(repeating:0,count:Int(width)-1),at:at),at:at) }
        }
    }
    func testNumericSignednessAndCharsetMetadataStayAligned() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4),decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        // FLOAT unsigned, DOUBLE signed, TINYINT unsigned, VARCHAR utf8mb4_bin.
        let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,4,4,5,1,15,4,4,8,40,0,15,1,1,160,2,1,46])
        let columns=try decoder.decode(event(19,body,at:at),at:at).wireColumns
        XCTAssertEqual(columns?.map(\.interpretation),[.float32,.float64,.unsigned,.utf8])
        XCTAssertEqual(columns?.map(\.isUnsigned),[true,false,true,nil])
        XCTAssertEqual(columns?.last?.collation,46)
    }
}
