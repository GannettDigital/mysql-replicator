import XCTest
import Foundation
@testable import ReplicatorCodec

final class CharacterSetValueTests:XCTestCase,BinlogFixtures {
    func testMultibyteCharPaddingDoesNotRemovePartOfACharacter() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let vectors:[(UInt8,ColumnInterpretation,[UInt8],[UInt8])] = [
            (1,.encodedText,[0xa4,0xa4,0,32],[0xa4,0xa4,0]),
            (35,.encodedText16BE,[32,32,0,0,0,32],[32,32,0,0]),
            (54,.encodedText16BE,[32,32,0,0,0,32],[32,32,0,0]),
            (56,.encodedText16LE,[0,32,0,0,32,0],[0,32,0,0]),
            (60,.encodedText32BE,[0,0,32,32,0,0,0,32],[0,0,32,32]),
            (248,.encodedText,[0x94,0x39,0xfc,0x36,0,32],[0x94,0x39,0xfc,0x36,0])
        ]
        for (id,kind,bytes,expected) in vectors {
            for operation:UInt8 in [30,31,32] {
                let decoder=try BinlogDecoder(),at=UInt64(fde.count+4)
                _ = try decoder.decode(fde,at:4)
                let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,254,2,254,64,1,3,1,id])
                let map=event(19,body,at:at),identity=try decoder.decode(map,at:at)
                XCTAssertEqual(identity.wireColumns?.first?.interpretation,kind)
                try decoder.reset(); _ = try decoder.decode(fde,at:4)
                _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[kind]))
                var row=Data([123,0,0,0,0,0,1,0,2,0,1,1])
                if operation == 31 { row.append(1) }
                row.append(contentsOf:[0,UInt8(bytes.count)]); row.append(contentsOf:bytes)
                if operation == 31 { row.append(1) }
                let rowAt=at+UInt64(map.count)
                let result=try decoder.decode(event(operation,row,at:rowAt),at:rowAt)
                XCTAssertEqual(operation == 30 ? result.rows.first?.after : result.rows.first?.before,[.binary(Data(expected))])
                if operation == 31 { XCTAssertEqual(result.rows.first?.after,[.null]) }
            }
        }
    }
    func testEveryCommonNativeCollationDecodesTextBytes() throws {
        let textIDs:[UInt8] = [33,45,46,83,223] + Array(192...215) + Array(224...247)
        let byteIDs:[UInt8] = [5,8,11,15,31,47,48,49,65,94]
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        for id in textIDs+byteIDs {
            let utf8=textIDs.contains(id)
            let raw:Data = utf8 ? Data([0xc3,0xa9,0,32]) : Data([0x41,0,32])
            let decoder=try BinlogDecoder(),at=UInt64(fde.count+4)
            _ = try decoder.decode(fde,at:4)
            let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,15,2,48,0,1,3,1,id])
            let map=event(19,body,at:at),identity=try decoder.decode(map,at:at)
            XCTAssertEqual(identity.wireColumns?.first?.interpretation,utf8 ? .utf8 : .encodedText,"collation \(id)")
            try decoder.reset(); _ = try decoder.decode(fde,at:4)
            _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[utf8 ? .utf8 : .encodedText]))
            var row=Data([123,0,0,0,0,0,1,0,2,0,1,1,0,UInt8(raw.count)])
            row.append(raw)
            let rowAt=at+UInt64(map.count)
            let result=try decoder.decode(event(30,row,at:rowAt),at:rowAt)
            XCTAssertEqual(result.rows.first?.after,[utf8 ? .text("é\0 ") : .binary(raw)],"collation \(id)")
        }
    }
    func testRawTextAndBinaryHaveDifferentPaddingRules() throws {
        // The same STRING wire type carries CHAR and BINARY. Optional charset
        // metadata or saved schema history must preserve this distinction.
        for full in [false,true] {
            for operation:UInt8 in [30,31,32] {
                let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
                let decoder=try BinlogDecoder(),at=UInt64(fde.count+4)
                _ = try decoder.decode(fde,at:4)
                let optional=full ? Data([3,3,8,63,11]) : Data()
                let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,3,254,254,15,6,254,4,254,4,4,0,7])+optional
                let map=event(19,body,at:at),identity=try decoder.decode(map,at:at)
                if full { XCTAssertEqual(identity.wireColumns?.map(\.interpretation),[.encodedText,.binary,.encodedText]) }
                try decoder.reset();_ = try decoder.decode(fde,at:4)
                _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.encodedText,.binary,.encodedText]))
                var rows=Data([123,0,0,0,0,0,1,0,2,0,3,7])
                if operation == 31 { rows.append(7) }
                rows.append(contentsOf:[0,4,0xe9,0x80,32,32,2,0xff,32,3,65,0,32])
                if operation == 31 { rows.append(7) }
                let rowAt=at+UInt64(map.count)
                let result=try decoder.decode(event(operation,rows,at:rowAt),at:rowAt)
                XCTAssertEqual(operation == 30 ? result.rows[0].after : result.rows[0].before,[.binary(Data([0xe9,0x80])),.binary(Data([0xff,32,0,0])),.binary(Data([65,0,32]))])
                if operation == 31 { XCTAssertEqual(result.rows[0].after,[.null,.null,.null]) }
            }
        }
    }
}
