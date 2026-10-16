import XCTest
import Foundation
@testable import ReplicatorCodec

final class JSONValueTests: XCTestCase, BinlogFixtures {
    func fixture(metadata:UInt8 = 4) throws -> (BinlogDecoder,UInt64) {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4), decoder=try BinlogDecoder()
        _ = try decoder.decode(fde,at:4)
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,245,1,metadata,1]),at:at)
        let identity=try decoder.decode(map,at:at)
        XCTAssertEqual(identity.wireColumns?.first?.interpretation,.json)
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.json]))
        return (decoder,at+UInt64(map.count))
    }
    func body(_ doc:Data,operation:UInt8) -> Data {
        var result=Data([123,0,0,0,0,0,1,0,2,0,1,1])
        if operation == 31 { result.append(1) }
        result.append(0); result.append(le(UInt32(doc.count))); result.append(doc)
        if operation == 31 { result.append(0); result.append(contentsOf:[2,0,0,0,4,0]) }
        result.append(1); if operation == 31 { result.append(1) }
        return result
    }
    func testFullDocumentsAcrossAllRowOperations() throws {
        let vectors:[(Data,String)] = [
            (Data(),"null"),(Data([4,0]),"null"),(Data([4,1]),"true"),(Data([4,2]),"false"),
            (Data([5,255,255]),"-1"),(Data([6,255,255]),"65535"),
            (Data([7])+le(Int32.min),"-2147483648"),(Data([8])+le(UInt32.max),"4294967295"),
            (Data([9])+le(Int64.min),"-9223372036854775808"),(Data([10])+le(UInt64.max),"18446744073709551615"),
            (Data([11])+le(Double(1.0).bitPattern),"1.0"),
            (Data([11])+le(Double(-0.0).bitPattern),"-0.0"),
            (Data([11])+le(UInt64(1)),"5e-324"),
            (Data([12,4])+Data("🙂".utf8),"\"🙂\""),
            // Small array: inlined integer and literal, followed by a string.
            (Data([2,3,0,15,0,5,1,0,4,0,0,12,13,0,1,120]),"[1,null,\"x\"]"),
            // Small object: one key followed by an inlined uint16.
            (Data([0,1,0,12,0,11,0,1,0,6,255,255,97]),"{\"a\":65535}"),
            (Data([3,1,0,0,0,13,0,0,0,8,255,255,255,255]),"[4294967295]"),
            (Data([1,0,0,0,0,8,0,0,0]),"{}")]
        for (doc,text) in vectors {
            for operation:UInt8 in [30,31,32] {
                let (decoder,at)=try fixture()
                let rows=try decoder.decode(event(operation,body(doc,operation:operation),at:at),at:at).rows
                guard case .json(let document)=(operation == 30 ? rows.first?.after : rows.first?.before)?.first else { return XCTFail("missing JSON") }
                XCTAssertTrue(try document.matchesTargetText(text),text)
                if [6,8,10].contains(doc.first ?? 0) { XCTAssertEqual(document.scalarChecks.first?.type,"UNSIGNED INTEGER") }
                if operation == 31 { XCTAssertEqual(rows.first?.after,[.json(try JSONDocument(text:"null"))]) }
                XCTAssertEqual(operation == 30 ? rows.last?.after : rows.last?.before,[.null])
            }
        }
    }
    func testNativeJSONDecimalUsesInternalPaddedPrecision() throws {
        // MySQL 8.4 JSON_OBJECT('decimal', CAST(value AS DECIMAL(65,30))).
        // The opaque payload uses precision 66, not SQL's limit of 65.
        let native=Data([15,246,32,66,30,127,67,158,177,202,72,64,120,202,241,203,63,208,248,160,134,248,164,50,234,255,67,158,177,202,72,64,120,252,133])
        let (decoder,at)=try fixture()
        let row=try decoder.decode(event(30,body(native,operation:30),at:at),at:at).rows[0]
        guard case .json(let doc)=row.after?[0] else { return XCTFail("missing JSON decimal") }
        XCTAssertEqual(doc.typedValues[0].scalar.precision,66)
        XCTAssertEqual(doc.typedValues[0].scalar.scale,30)
        XCTAssertEqual(doc.typedValues[0].scalar.value,"-12345678901234567890123456789012345.123456789012345678901234567890")
        XCTAssertEqual(doc.typedValues[0].scalar.rawBytes,Data(native.dropFirst(3)))
    }
    func testMalformedOpaqueAndPartialValuesFail() throws {
        for metadata:UInt8 in [0,1,2,3,5] { XCTAssertThrowsError(try fixture(metadata:metadata)) }
        for doc in [Data([4,3]),Data([4,0,0]),Data([12,1,255]),Data([2,1,0,4,0]),Data([2,1,0,7,0,12,255,255]),Data([11])+le(UInt64(0x7ff0000000000000)),Data([15,246,0])] {
            let (decoder,at)=try fixture()
            XCTAssertThrowsError(try decoder.decode(event(30,body(doc,operation:30),at:at),at:at),doc.base64EncodedString())
        }
        let (decoder,at)=try fixture()
        failure(2) { _ = try decoder.decode(event(39,Data(),at:at),at:at) }
    }
    func testDocumentComparisonRetainsTypesIntegersAndUTF8() throws {
        let a=try JSONDocument(text:#" {"b":18446744073709551615,"a":[null,true,1.00e0,"\u0061"]} "#)
        let b=try JSONDocument(text:#"{"a":[null,true,1.0,"a"],"b":18446744073709551615}"#)
        XCTAssertEqual(a,b)
        XCTAssertNotEqual(try JSONDocument(text:"1"),try JSONDocument(text:"1.0"))
        XCTAssertNotEqual(try JSONDocument(text:"-0.0"),try JSONDocument(text:"0.0"))
        XCTAssertNotEqual(try JSONDocument(text:"9007199254740992"),try JSONDocument(text:"9007199254740993"))
        XCTAssertNotEqual(try JSONDocument(text:#""é""#),try JSONDocument(text:#""e\u0301""#))
        XCTAssertEqual(try JSONDocument(text:#"{"é":1,"e\u0301":2}"#).text,#"{"é":2,"é":1}"#)
        for invalid in ["", "01", "+1", "NaN", "1e309", "18446744073709551616", "-9223372036854775809", "[1,]", "{\"a\":1,\"a\":2}", "true false", #""\ud800""#, "[", "{", "1.", String(repeating:"[",count:100)+"0"+String(repeating:"]",count:100)] {
            XCTAssertThrowsError(try JSONDocument(text:invalid),invalid)
        }
        let allowed=String(repeating:"[",count:99)+"0"+String(repeating:"]",count:99)
        XCTAssertNoThrow(try JSONDocument(text:allowed))
    }
    func testJSONDoesNotConsumeCharacterMetadata() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4), decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let data=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,2,245,15,3,4,40,0,3,2,1,46])
        let columns=try decoder.decode(event(19,data,at:at),at:at).wireColumns
        XCTAssertEqual(columns?.map(\.interpretation),[.json,.utf8])
        XCTAssertEqual(columns?.map(\.collation),[0,46])
    }
}
