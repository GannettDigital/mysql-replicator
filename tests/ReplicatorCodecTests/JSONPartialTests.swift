import XCTest
import Foundation
@testable import ReplicatorCodec

extension JSONValueTests {
    func opaque(_ type:UInt8,_ raw:Data) -> Data { Data([15,type,UInt8(raw.count)])+raw }
    func decodedDocument(_ raw:Data) throws -> JSONDocument {
        let (decoder,at)=try fixture()
        let value=try decoder.decode(event(30,body(raw,operation:30),at:at),at:at).rows[0].after![0]
        guard case .json(let document)=value else { throw NSError(domain:"test",code:1) }
        return document
    }
    func packedDateTime(_ year:Int64,_ month:Int64,_ day:Int64,_ hour:Int64=0,_ minute:Int64=0,_ second:Int64=0,_ micros:Int64=0) -> Data {
        le((((((year*13+month)<<5)|day)<<17)|(hour<<12)|(minute<<6)|second)<<24|micros)
    }
    func testTypedScalarsRetainRawBytesAndNativeTypes() throws {
        let date=packedDateTime(2024,2,29)
        let datetime=packedDateTime(2024,2,29,12,34,56,123456)
        let time=le(-(((Int64(838)<<12)|(59<<6)|59)<<24|123456))
        let vectors:[(UInt8,Data,String,String)] = [
            (246,Data([5,2,0x80,123,45]),"DECIMAL","123.45"),
            (246,Data([5,2,0x7f,0x84,0xd2]),"DECIMAL","-123.45"),
            (10,date,"DATE","2024-02-29"),
            (10,Data(repeating:0,count:8),"DATE","0000-00-00"),
            (11,time,"TIME","-838:59:59.123456"),
            (12,datetime,"DATETIME","2024-02-29 12:34:56.123456"),
            (7,datetime,"TIMESTAMP","2024-02-29 12:34:56.123456"),
            (252,Data([0,255]),"BLOB","base64:type252:AP8="),
            (16,Data([1,255]),"BIT","base64:type16:Af8="),
            (13,Data("2024".utf8),"OPAQUE","base64:type13:MjAyNA==")]
        for (code,raw,type,display) in vectors {
            let doc=try decodedDocument(opaque(code,raw)), scalar=try XCTUnwrap(doc.typedValues.first?.scalar)
            XCTAssertEqual(scalar.rawBytes,raw)
            XCTAssertEqual(scalar.type,Int(code)); XCTAssertEqual(scalar.typeName,type)
            XCTAssertEqual(scalar.display,display)
            XCTAssertEqual(doc.scalarChecks.first?.type,type)
            let text=code == 246 ? display : String(decoding:try JSONEncoder().encode(display),as:UTF8.self)
            XCTAssertTrue(try doc.matchesTargetText(text))
            XCTAssertNotEqual(doc,try JSONDocument(text:text))
        }
        let decimal=try decodedDocument(opaque(246,Data([5,2,0x80,123,45])))
        XCTAssertEqual(decimal.typedValues.first?.scalar.precision,5)
        XCTAssertEqual(decimal.typedValues.first?.scalar.scale,2)
        for raw in [Data([15,10,7])+Data(repeating:0,count:7),opaque(12,le(Int64.min)),opaque(246,Data([1,2,0])),opaque(246,Data([5,2,0x80]))] {
            XCTAssertThrowsError(try decodedDocument(raw))
        }
    }
    func diff(_ operation:UInt8,_ path:String,_ value:Data?=nil) -> Data {
        var bytes=Data([operation,UInt8(path.utf8.count)])+Data(path.utf8)
        if let value { bytes.append(UInt8(value.count)); bytes.append(value) }
        return bytes
    }
    func partialBody(_ before:Data,_ after:Data,options:UInt8=1,bitmap:UInt8=1) -> Data {
        var bytes=Data([123,0,0,0,0,0,1,0,2,0,1,1,1,0])+le(UInt32(before.count))+before
        bytes.append(options); if options == 1 { bytes.append(bitmap) }
        bytes.append(0); bytes.append(le(UInt32(after.count))); bytes.append(after)
        return bytes
    }
    func partial(_ before:Data,_ delta:Data,options:UInt8=1,bitmap:UInt8=1) throws -> JSONDocument {
        let (decoder,at)=try fixture()
        let decoded=try decoder.decode(event(39,partialBody(before,delta,options:options,bitmap:bitmap),at:at),at:at)
        XCTAssertEqual(decoded.rowFlags,1)
        guard case .json(let doc)=decoded.rows[0].after![0] else { throw NSError(domain:"test",code:1) }
        return doc
    }
    func testPartialEventRebuildsAfterImageAndKeepsTypedValues() throws {
        // Native small array [1,null,"x"].
        let before=Data([2,3,0,15,0,5,1,0,4,0,0,12,13,0,1,120])
        let decimal=opaque(246,Data([5,2,0x80,123,45]))
        let delta=diff(0,"$[1]",decimal)+diff(1,"$[1]",Data([4,1]))+diff(2,"$[last]")
        let after=try partial(before,delta)
        XCTAssertTrue(try after.matchesTargetText("[1,true,123.45]"))
        XCTAssertEqual(after.scalarChecks.map(\.type),["INTEGER","BOOLEAN","DECIMAL"])
        XCTAssertEqual(try partial(before,diff(2,"$[ last - 0 ]")),try JSONDocument(text:"[1,null]"))
        XCTAssertEqual(try partial(before,Data()),try decodedDocument(before))
        XCTAssertEqual(try partial(before,Data([4,0]),options:0),try JSONDocument(text:"null"))
        XCTAssertEqual(try partial(before,Data([4,0]),bitmap:0),try JSONDocument(text:"null"))
        // Options and partial bitmaps occur for each row pair, not once per event.
        let first=partialBody(before,delta), second=partialBody(before,Data())
        let (decoder,at)=try fixture()
        let decoded=try decoder.decode(event(39,first+second.dropFirst(13),at:at),at:at)
        XCTAssertEqual(decoded.rows.count,2)
        XCTAssertEqual(decoded.rows[0].after,[.json(after)])
        XCTAssertEqual(decoded.rows[1].after,[.json(try decodedDocument(before))])
    }
    func testMalformedPartialEventsFail() throws {
        let before=Data([2,1,0,7,0,5,1,0])
        let changes=[diff(0,"$[9]",Data([4,0])),diff(2,"$.missing"),diff(1,"$",Data([4,0])),diff(0,"$[*]",Data([4,0])),diff(0,"$[0 0]",Data([4,0])),diff(0,"$[l ast]",Data([4,0])),Data([3,0]),Data([0,251]),diff(0,"$[0]",Data([4,3]))]
        for change in changes { XCTAssertThrowsError(try partial(before,change)) }
        XCTAssertThrowsError(try partial(before,Data(),options:2))
        let valid=diff(0,"$[0]",Data([4,0]))
        for count in 1..<valid.count { XCTAssertThrowsError(try partial(before,Data(valid.prefix(count)))) }
    }
    func testPartialPathsAndArrayInsertRules() throws {
        let doc=try JSONDocument(text:#"{"a.b":[1,2],"é":0,"e\u0301":9}"#)
        func apply(_ delta:String,_ maximum:Int=10000) throws -> JSONDocument { try doc.applying(delta:Data(delta.utf8),maximumBytes:maximum) }
        let edits=#"[{"operation":1,"path":"$.\"a.b\"[99]","value":{"text":"3","typed":[]}},{"operation":1,"path":"$.\"a.b\"[last-99]","value":{"text":"0","typed":[]}},{"operation":0,"path":"$.\"é\"","value":{"text":"null","typed":[]}},{"operation":2,"path":"$.\"é\""}]"#
        XCTAssertEqual(try apply(edits),try JSONDocument(text:#"{"a.b":[0,1,2,3],"é":null}"#))
        XCTAssertThrowsError(try apply(edits,100))
        for delta in [#"[{"operation":1,"path":"$.é","value":{"text":"0","typed":[]}}]"#,#"[{"operation":2,"path":"$.missing"}]"#,#"[{"operation":0,"path":"$.é.x","value":{"text":"0","typed":[]}}]"#] {
            XCTAssertThrowsError(try apply(delta))
        }
    }
}

extension JSONValueTests {
    func testPartialBitmapCountsJSONColumnsNotAllColumns() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4), decoder=try BinlogDecoder()
        _ = try decoder.decode(fde,at:4)
        // Three columns: JSON, INT, JSON. Only the second JSON is partial.
        let map=event(19,Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,3,245,3,245,2,4,4,5]),at:at)
        let identity=try decoder.probeTable(map,at:at)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.json,.signed,.json]))
        let before=Data([2,1,0,7,0,5,1,0]),delta=diff(0,"$[0]",Data([4,1]))
        let old=Data([0,2,0,0,0,4,0])+le(Int32(7))+le(UInt32(before.count))+before
        let new=Data([1,2,0,2,0,0,0,4,0])+le(Int32(8))+le(UInt32(delta.count))+delta
        let body=Data([123,0,0,0,0,0,1,0,2,0,3,7,7])+old+new
        let position=at+UInt64(map.count)
        let result=try decoder.decode(event(39,body,at:position),at:position)
        XCTAssertEqual(result.rows.first?.after,[.json(try JSONDocument(text:"null")),.signed(8),.json(try JSONDocument(text:"[true]"))])
    }
    func testPartialErrorsCarryEventPositionAndPoisonDecoder() throws {
        let (decoder,at)=try fixture()
        let before=Data([2,1,0,7,0,5,1,0])
        let frame=event(39,partialBody(before,diff(2,"$[9]")),at:at)
        XCTAssertThrowsError(try decoder.decode(frame,at:at)) { error in
            XCTAssertEqual((error as? DecoderError)?.offset,at)
            XCTAssertEqual((error as? DecoderError)?.eventType,39)
        }
        failure(6) { _ = try decoder.decode(frame,at:at) }
        XCTAssertNoThrow(try decoder.reset())
    }
    func testNativeUnicodeIdentifiersInPartialPaths() throws {
        let doc=try JSONDocument(text:#"{"e\u0301":1,"a\u200d":2}"#)
        let delta=#"[{"operation":2,"path":"$.é"},{"operation":0,"path":"$.a‍","value":{"text":"3","typed":[]}}]"#
        XCTAssertEqual(try doc.applying(delta:Data(delta.utf8),maximumBytes:10000),try JSONDocument(text:#"{"a\u200d":3}"#))
    }
}
