import XCTest
import Foundation
@testable import ReplicatorCodec

final class SpatialValueTests:XCTestCase,BinlogFixtures {
    // SRID 4326, little-endian POINT(1 2). Keep coordinates as stored.
    let point=Data([0xe6,0x10,0,0,1,1,0,0,0,0,0,0,0,0,0,0xf0,0x3f,0,0,0,0,0,0,0,0x40])
    func fixture(optional:Data=Data(),metadata:UInt8=4) throws -> (BinlogDecoder,UInt64) {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4),decoder=try BinlogDecoder()
        _ = try decoder.decode(fde,at:4)
        // Geometry followed by VARCHAR: spatial metadata must not consume charset.
        let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,2,255,15,3,metadata,40,0,3])+optional
        let map=event(19,body,at:at),identity=try decoder.decode(map,at:at)
        XCTAssertEqual(identity.wireColumns?[0].interpretation,.binary)
        XCTAssertEqual(identity.wireColumns?[1].collation,optional.isEmpty ? 0 : 46)
        XCTAssertEqual(identity.wireColumns?[0].geometryType,optional.isEmpty ? nil : 1)
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.binary,.utf8]))
        return (decoder,at+UInt64(map.count))
    }
    func testSpatialBytesAndAdjacentTextAcrossRowOperations() throws {
        for optional in [Data(),Data([7,1,1,2,1,46])] {
            for operation:UInt8 in [30,31,32] {
                let (decoder,at)=try fixture(optional:optional)
                var body=Data([123,0,0,0,0,0,1,0,2,0,2,3])
                if operation == 31 { body.append(3) }
                let image=Data([0])+le(UInt32(point.count))+point+Data([2,0xc3,0xa9])
                body.append(image)
                if operation == 31 { body.append(3) } // SQL NULL for both after columns.
                let result=try decoder.decode(event(operation,body,at:at),at:at)
                XCTAssertEqual(operation == 30 ? result.rows[0].after : result.rows[0].before,[.binary(point),.text("é")])
                if operation == 31 { XCTAssertEqual(result.rows[0].after,[.null,.null]) }
            }
        }
    }
    func testSpatialFramingAndMetadataRejectTruncation() throws {
        for width:UInt8 in [0,1,2,3,5] { XCTAssertThrowsError(try fixture(metadata:width)) }
        // A two-column map has only one geometry column.
        XCTAssertThrowsError(try fixture(optional:Data([7,2,1,2])))
        let (decoder,at)=try fixture()
        let body=Data([123,0,0,0,0,0,1,0,2,0,2,3,0])+le(UInt32(point.count+100))+point
        XCTAssertThrowsError(try decoder.decode(event(30,body,at:at),at:at))
    }
}
