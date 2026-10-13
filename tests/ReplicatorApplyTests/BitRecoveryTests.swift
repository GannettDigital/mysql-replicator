import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec
@testable import ReplicatorCapture

extension ResumeTests {
    func testBitKeyAndValueSurviveRelayInspectionAndRestart() throws {
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
        let table=ApplyTable(database:"poc",table:"bits",columns:[ApplyColumn(name:"id",type:"bit(64)",nullable:false,collation:nil),ApplyColumn(name:"v",type:"bit(9)",nullable:true,collation:nil)],primaryKey:"id")
        let begin=original.events.first { $0.eventType == 2 }!
        let gtid=original.events.first { $0.eventType == 33 }!
        let xid=original.events.last!
        func body(_ event:DecodedEvent) -> Data { Data(Data(base64Encoded:event.rawBase64!)!.dropFirst(19).dropLast(4)) }
        let map=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,4])+Data("bits".utf8)+Data([0,2,16,16,4,0,8,1,1,2])
        let row=Data([123,0,0,0,0,0,1,0,2,0,2,3,0])+Data(repeating:255,count:8)+Data([1,255])
        var events:[DecodedEvent]=[]
        let start=offset
        for (type,payload):(UInt8,Data) in [(33,body(gtid)),(2,body(begin)),(19,map),(30,row),(16,body(xid))] {
            let raw=frame(type,payload)
            var history:TableSchema?
            if type == 19 {
                let probe=try BinlogDecoder(); _ = try probe.decode(Data(input[4..<4+fdeSize]),at:4)
                let identity=try probe.decode(raw,at:UInt64(4+fdeSize))
                history=TableSchema(offset:offset,eventSHA256:identity.sha256,database:"poc",table:"bits",tableID:"123",columns:[.unsigned,.unsigned])
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
        XCTAssertEqual(report.pending.first?.rows.first?.afterKey,[.unsigned(UInt64.max)])
        XCTAssertEqual(report.pending.first?.rows.first?.after,[.unsigned(UInt64.max),.unsigned(511)])
        XCTAssertEqual(report.pending.first?.rows.first?.schema.columns.map(\.type),["bit(64)","bit(9)"])
        _ = try Recovery.resolve(configuration:configuration,action:.retry,gtids:helper.sid+":11",reason:"unit fixture issued no SQL")
        let resumed=try StateStore(configuration:configuration,initialize:false)
        XCTAssertEqual(resumed.gtids,helper.sid+":1-10")
        XCTAssertEqual(resumed.transactions,0)
    }
}
