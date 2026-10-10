import XCTest
import Foundation
import ReplicatorCodec

extension DecoderTests {
    func testTableProbePreservesStreamAndGoldenDecode() throws {
        let input=frames(try Data(contentsOf:directory.appendingPathComponent("Synthetic/typed.binlog")))
        let history=try schema("typed").indexed()
        let probed=try BinlogDecoder(), plain=try BinlogDecoder()
        for (offset,frame) in input {
            if frame[4] == 19 {
                let identity=try probed.probeTable(frame,at:offset,filterTable:true)
                let metadata=try probed.probeTable(frame,at:offset)
                XCTAssertEqual(identity.sha256,metadata.sha256)
                XCTAssertEqual(identity.database,metadata.database)
                XCTAssertEqual(identity.tableID,metadata.tableID)
                XCTAssertNotNil(metadata.wireColumns)
            }
            XCTAssertEqual(try probed.decode(frame,at:offset,schema:history[offset],includeRaw:true),
                           try plain.decode(frame,at:offset,schema:history[offset],includeRaw:true))
        }
    }
    func testTableProbeRejectsMissingFormatBadOffsetCRCAndNonTable() throws {
        let input=frames(try Data(contentsOf:directory.appendingPathComponent("Synthetic/typed.binlog")))
        let map=try XCTUnwrap(input.first { $0.1[4] == 19 })
        failure(2) { _ = try BinlogDecoder().probeTable(map.1,at:map.0) }
        for mode in 0..<3 {
            let decoder=try BinlogDecoder()
            for (offset,frame) in input where offset < map.0 { _ = try decoder.decode(frame,at:offset) }
            if mode == 0 { failure(2) { _ = try decoder.probeTable(map.1,at:map.0+1) } }
            if mode == 1 {
                var corrupt=map.1; corrupt[corrupt.count-1] ^= 1
                failure(3) { _ = try decoder.probeTable(corrupt,at:map.0) }
            }
            if mode == 2 { failure(1) { _ = try decoder.probeTable(event(3,Data(),at:map.0),at:map.0) } }
            failure(6) { _ = try decoder.decode(map.1,at:map.0) }
        }
    }
    func testGTIDSIDCacheHandlesRepeatedChangedAndResetIdentity() throws {
        let input=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))
        let template=try XCTUnwrap(input.first { $0.1[4] == 33 }).1
        let decoder=try BinlogDecoder()
        _ = try decoder.decode(input[0].1,at:4)
        var offset=UInt64(input[0].1.count+4)
        let a=Data((0..<16).map { UInt8($0) }), b=Data(repeating:0xff,count:16)
        for (index,uuid) in [a,a,b,b,a].enumerated() {
            var body=Data(template[19..<template.count-4]);body.replaceSubrange(1..<17,with:uuid)
            body.replaceSubrange(17..<25,with:le(UInt64(index+1)))
            let frame=event(33,body,at:offset), decoded=try decoder.decode(frame,at:offset)
            guard case .gtid(let id)=decoded.control else { return XCTFail("missing GTID") }
            XCTAssertEqual(id.sid,uuid == a ? "00010203-0405-0607-0809-0a0b0c0d0e0f" : "ffffffff-ffff-ffff-ffff-ffffffffffff")
            XCTAssertEqual(id.sequence,String(index+1))
            offset += UInt64(frame.count)
            if index == 3 { try decoder.reset(); _ = try decoder.decode(input[0].1,at:4); offset=UInt64(input[0].1.count+4) }
        }
    }
}
