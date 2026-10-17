import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec
@testable import ReplicatorCapture

extension ResumeTests {
    func testWideEncodedTextSurvivesRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["varchar(4)","char(4)"],codes:[15,254],metadata:[16,0,254,16],
            payload:Data([4,0x20,0x20,0,0,8,0,0,0x20,0x20,0,0,0,32]),
            expected:[.binary(Data([0x20,0x20,0,0])),.binary(Data([0,0,0x20,0x20]))],
            collations:["utf16_bin","utf32_bin"],characterSets:["utf16","utf32"])
    }
    func testAdditionalCollationsSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["varchar(4)","char(4)"],codes:[15,254],metadata:[16,0,254,4],
            payload:Data([2,0xc3,0xa9,4,0xe9,0,32,32]),
            expected:[.text("é"),.binary(Data([0xe9,0]))],
            collations:["utf8mb4_unicode_520_ci","latin1_general_cs"],characterSets:["utf8mb4","latin1"])
    }
    func testEncodedTextKeyAndValueSurviveRelayInspectionAndRestart() throws {
        // latin1 key bytes are not valid UTF-8. ASCII CHAR keeps NUL and trims
        // spaces. Recovery must reconstruct both from the relay and saved schema.
        try scalarRecovery(types:["varchar(4)","char(4)"],codes:[15,254],metadata:[4,0,254,4],
            payload:Data([3,0xe9,0x80,0xff,4,65,0,32,32]),
            expected:[.binary(Data([0xe9,0x80,0xff])),.binary(Data([65,0]))],
            collations:["latin1_swedish_ci","ascii_bin"],characterSets:["latin1","ascii"])
    }

    func testZeroWidthValuesSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["int","varchar(0)"],codes:[3,15],metadata:[0,0],payload:Data([1,0,0,0,0]),expected:[.signed(1),.text("")],collations:[nil,"utf8mb4_bin"],characterSets:[nil,"utf8mb4"])
        try scalarRecovery(types:["int","varchar(0)"],codes:[3,15],metadata:[0,0],payload:Data([1,0,0,0,0]),expected:[.signed(1),.binary(Data())],collations:[nil,"utf16_bin"],characterSets:[nil,"utf16"])
        try scalarRecovery(types:["int","varbinary(0)"],codes:[3,15],metadata:[0,0],payload:Data([1,0,0,0,0]),expected:[.signed(1),.binary(Data())])
    }
    func testBinaryDefaultsSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["binary(4)","varbinary(4)"],codes:[254,15],metadata:[254,4,4,0],
            payload:Data([4,255,0,1,0,3,255,0,2]),
            expected:[.binary(Data([255,0,1,0])),.binary(Data([255,0,2]))],
            binaryDefaults:[Data([255,0,1,0]),Data([255,0,2])])
    }
    func testBinaryChoiceLabelsSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["enum(X'ff',X'61')","set(X'80',X'62')"],codes:[254,254],metadata:[247,1,248,1],
            payload:Data([2,3]),expected:[.unsigned(2),.unsigned(3)],
            collations:["binary","binary"],characterSets:["binary","binary"],
            choiceLabels:[[Data([0xff]),Data([0x61])],[Data([0x80]),Data([0x62])]])
    }
    func testEncodedChoiceLabelsSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["enum('é','ÿ')","set('中','†')"],codes:[254,254],metadata:[247,1,248,1],
            payload:Data([2,3]),expected:[.unsigned(2),.unsigned(3)],
            collations:["latin1_bin","utf16_bin"],characterSets:["latin1","utf16"],
            choiceLabels:[[Data([0xe9]),Data([0xff])],[Data([0x4e,0x2d]),Data([0x20,0x20])]])
    }
    func testEnumZeroAndEmptyLabelSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["enum('','a')","enum('','b')"],codes:[254,254],metadata:[247,1,247,1],
                           payload:Data([0,1]),expected:[.unsigned(0),.unsigned(1)],
                           collations:["utf8mb4_bin","utf8mb4_bin"])
    }
    func testZerofillSchemaAndNumericValuesSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["int(10) unsigned zerofill","decimal(8,2) unsigned zerofill"],codes:[3,246],metadata:[8,2],
                           payload:Data([1,0,0,0,0x80,0,1,25]),expected:[.unsigned(1),.decimal("1.25")])
    }
    func testBitKeyAndValueSurviveRelayInspectionAndRestart() throws {
        try scalarRecovery(types:["bit(64)","bit(9)"],codes:[16,16],metadata:[0,8,1,1],
                           payload:Data(repeating:255,count:8)+Data([1,255]),
                           expected:[.unsigned(UInt64.max),.unsigned(511)])
    }
    func testFloatingValuesSurviveRelayInspectionAndRestart() throws {
        for (key,value):(UInt64,UInt32) in [(0x3fb999999999999a,0x3dcccccd),(0x8000000000000000,1),(1,0x80000000)] {
            var k=key.littleEndian,v=value.littleEndian
            let data=withUnsafeBytes(of:&k) { Data($0) }+withUnsafeBytes(of:&v) { Data($0) }
            try scalarRecovery(types:["double","float"],codes:[5,4],metadata:[8,4],
                               payload:data,expected:[.float64(key),.float32(value)])
        }
    }
    func testFixedScaleValuesSurviveRelayInspectionAndRestart() throws {
        let key=Double(-1.234568).bitPattern,value=Float(1.24).bitPattern
        var k=key.littleEndian,v=value.littleEndian
        let data=withUnsafeBytes(of:&k) { Data($0) }+withUnsafeBytes(of:&v) { Data($0) }
        try scalarRecovery(types:["double(20,6)","float(10,2)"],codes:[5,4],metadata:[8,4],
                           payload:data,expected:[.float64(key),.float32(value)])
    }
    func testJSONSurvivesRelayInspectionAndRestart() throws {
        // JSON UINT64 maximum, not representable through a Double conversion.
        let document=Data([10])+Data(repeating:255,count:8)
        let payload=Data([1,0,0,0,9,0,0,0])+document
        try scalarRecovery(types:["int","json"],codes:[3,245],metadata:[4],payload:payload,
            expected:[.signed(1),.json(try JSONDocument(text:"18446744073709551615"))])
    }
    func testTypedJSONSurvivesRelayInspectionAndRestart() throws {
        let document=Data([15,246,5,5,2,0x80,123,45])
        let payload=Data([1,0,0,0,8,0,0,0])+document
        let expected=try JSONDocument(source:Data(#"{"text":"null","typed":[{"path":"$","type":246,"value":"123.45","rawHex":"0502807b2d","precision":5,"scale":2}]}"#.utf8))
        try scalarRecovery(types:["int","json"],codes:[3,245],metadata:[4],payload:payload,
            expected:[.signed(1),.json(expected)])
    }
    private func scalarRecovery(types:[String],codes:[UInt8],metadata:[UInt8],payload:Data,expected:[DecodedValue],collations:[String?]=[nil,nil],characterSets:[String?]=[nil,nil],choiceLabels:[[Data]?]=[nil,nil],binaryDefaults:[Data?]=[nil,nil]) throws {

        let path=try directory(), configuration=try helper.config(path.path,profile:ReplicationProfile.mysql57To84InnoDB.rawValue)
        let input=try Data(contentsOf:helper.root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
        let fdeSize=(0..<4).reduce(0) { $0 | Int(input[13+$1]) << (8*$1) }
        let decoder=try BinlogDecoder()
        let format=try decoder.decode(Data(input[4..<4+fdeSize]),at:4,includeRaw:true)
        var offset=UInt64(4+fdeSize)
        func le<T:FixedWidthInteger>(_ value:T) -> Data {
            var value=value.littleEndian; return withUnsafeBytes(of:&value) { Data($0) }
        }
        func frame(_ type:UInt8,_ body:Data) -> Data {
            let size=UInt32(body.count+23)
            var result=le(UInt32(1700000000))+Data([type])+le(UInt32(1))+le(size)+le(UInt32(offset)+size)+le(UInt16(0))+body
            var crc:UInt32=0xffffffff
            for byte in result { crc ^= UInt32(byte); for _ in 0..<8 { crc=(crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            result.append(le(crc ^ 0xffffffff)); return result
        }
        let original=try helper.groups()[0]
        let table=ApplyTable(database:"poc",table:"scalars",columns:[ApplyColumn(name:"id",type:types[0],nullable:false,collation:collations[0],characterSet:characterSets[0],choiceLabels:choiceLabels[0],binaryDefaultBytes:binaryDefaults[0]),ApplyColumn(name:"v",type:types[1],nullable:true,collation:collations[1],characterSet:characterSets[1],choiceLabels:choiceLabels[1],binaryDefaultBytes:binaryDefaults[1])],primaryKey:"id")
        let begin=original.events.first { $0.eventType == 2 }!
        let gtid=original.events.first { $0.eventType == 33 }!
        let xid=original.events.last!
        func body(_ event:DecodedEvent) -> Data { Data(Data(base64Encoded:event.rawBase64!)!.dropFirst(19).dropLast(4)) }
        var map=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,7])+Data("scalars".utf8)
        map.append(contentsOf:[0,2]); map.append(contentsOf:codes); map.append(UInt8(metadata.count))
        map.append(contentsOf:metadata); map.append(2)
        if codes.contains(4) { map.append(contentsOf:[1,1,0]) } // Signedness for both floating-point columns.
        let row=Data([123,0,0,0,0,0,1,0,2,0,2,3,0])+payload
        var events:[DecodedEvent]=[]
        let start=offset
        for (type,payload):(UInt8,Data) in [(33,body(gtid)),(2,body(begin)),(19,map),(30,row),(16,body(xid))] {
            let raw=frame(type,payload)
            var history:TableSchema?
            if type == 19 {
                let probe=try BinlogDecoder(); _ = try probe.decode(Data(input[4..<4+fdeSize]),at:4)
                let identity=try probe.decode(raw,at:UInt64(4+fdeSize))
                history=TableSchema(offset:offset,eventSHA256:identity.sha256,database:"poc",table:"scalars",tableID:"123",columns:table.columns.map(\.interpretation))
            }
            events.append(try decoder.decode(raw,at:offset,schema:history,includeRaw:true)); offset += UInt64(raw.count)
        }
        let group=CompleteTransaction(start:.init(file:"binlog.000003",position:start),end:.init(file:"binlog.000003",position:offset),gtid:original.gtid,anonymous:false,outcome:.committed,events:events)
        do {
            let store=try StateStore(configuration:configuration)
            try store.bindTargetIdentity(target); try store.running()
            try store.append(.init(kind:"formatContext",file:group.start.file,observedPosition:String(format.nextPosition),event:format,rawBase64:nil))
            try store.schema(table,event:events[2],coordinate:group.start)
            for event in events { try store.append(.init(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
            try store.beginBatch([.init(group:group,mutations:try DMLPlan.make(group,tables:[table]),relayEnd:store.relayLength)])
            try store.block("simulated stop before target write")
        }
        let report=try Recovery.inspect(configuration:configuration)
        XCTAssertEqual(report.pending.first?.rows.first?.afterKey,[expected[0]])
        XCTAssertEqual(report.pending.first?.rows.first?.after,expected)
        XCTAssertEqual(report.pending.first?.rows.first?.schema,table)
        _ = try Recovery.resolve(configuration:configuration,action:.retry,gtids:helper.sid+":11",reason:"unit fixture issued no SQL")
        let resumed=try StateStore(configuration:configuration,initialize:false)
        XCTAssertEqual(resumed.gtids,helper.sid+":1-10")
        XCTAssertEqual(resumed.transactions,0)
        let restored=try XCTUnwrap(resumed.currentSchemas.first)
        XCTAssertEqual(restored,table)
        let plan=try DMLSQLPlan(restored)
        for column in restored.columns where column.interpretation.isEncodedText {
            XCTAssertTrue(plan.insert.contains("CONVERT(? USING "+column.characterSet!+")"))
        }
        if restored.columns[0].interpretation.isEncodedText, let charset=characterSets[0] { XCTAssertTrue(plan.delete.contains("`id`=CONVERT(? USING "+charset+")")) }
    }
}
