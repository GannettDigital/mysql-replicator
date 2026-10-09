import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture

final class RelayMetadataTests: XCTestCase {
    private func temporaryFile(_ bytes: Data) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:url)
        addTeardownBlock { try FileManager.default.removeItem(at:url) }
        return url
    }
    private func frame(_ metadata: Data, _ raw: Data = Data([1,2,3])) -> Data {
        var data=Data()
        RelayMetadata.append(UInt32(metadata.count),to:&data)
        RelayMetadata.append(UInt32(raw.count),to:&data)
        data += metadata; data += raw
        return data
    }
    func testBinaryLayoutAndAllRecordKindsPreserveCoordinatesAndUTF8() throws {
        let value=RelayMetadata(kind:"event",file:"b",observedPosition:String(0x0102030405060708 as UInt64))
        XCTAssertEqual(try value.encoded(),Data([0x52,0x4d,0x44,1,1,8,7,6,5,4,3,2,1,1,0,0x62]))
        for kind in ["event","rotationAnnouncement","formatContext","heartbeat"] {
            for name in ["binlog.000003","quote\"backslash\\slash/é😀e\u{0301}",String(repeating:"a",count:255)] {
                for position in ["0","4",String(UInt64.max)] {
                    let original=RelayMetadata(kind:kind,file:name,observedPosition:position)
                    let (decoded,version)=try RelayMetadata.decoded(original.encoded())
                    XCTAssertEqual(version,1); XCTAssertEqual(decoded,original)
                    XCTAssertEqual(Array(decoded.file.utf8),Array(name.utf8))
                }
            }
        }
    }
    func testMalformedMetadataIsRejected() throws {
        for value in [RelayMetadata(kind:"future",file:"bin",observedPosition:"4"),
                      RelayMetadata(kind:"event",file:"",observedPosition:"4"),
                      RelayMetadata(kind:"event",file:"nul\0",observedPosition:"4"),
                      RelayMetadata(kind:"event",file:String(repeating:"é",count:128),observedPosition:"4"),
                      RelayMetadata(kind:"event",file:"bin",observedPosition:"18446744073709551616"),
                      RelayMetadata(kind:"event",file:"bin",observedPosition:"-1"),
                      RelayMetadata(kind:"event",file:"bin",observedPosition:"04")] {
            XCTAssertThrowsError(try value.encoded())
        }
        let good=try RelayMetadata(kind:"event",file:"b",observedPosition:"4").encoded()
        for end in 0..<good.count { XCTAssertThrowsError(try RelayMetadata.decoded(Data(good.prefix(end)))) }
        for (index,byte) in [(0,0),(3,2),(4,0),(4,5),(13,2),(15,255),(15,0)] {
            var invalid=good; invalid[index]=UInt8(byte)
            XCTAssertThrowsError(try RelayMetadata.decoded(invalid))
        }
        XCTAssertThrowsError(try RelayMetadata.decoded(good+Data([0])))
    }
    func testInspectorReadsMixedLegacyAndBinaryIncludingRotationWithoutChangingRawBytes() throws {
        let values=[RelayMetadata(kind:"event",file:"binlog.000003",observedPosition:"300"),
                    RelayMetadata(kind:"rotationAnnouncement",file:"binlog.000004",observedPosition:"4"),
                    RelayMetadata(kind:"formatContext",file:"binlog.000004",observedPosition:"4"),
                    RelayMetadata(kind:"heartbeat",file:"binlog.000004",observedPosition:"123")]
        let raw=Data((0...255).map(UInt8.init))
        let legacy=try JSONEncoder().encode(values[0])
        let frames=try [frame(legacy,raw)]+values.dropFirst().map { frame(try $0.encoded(),raw) }
        let bytes=frames.reduce(Data(),+),url=try temporaryFile(bytes)
        var output:[RelayInspection.Record]=[]
        try RelayInspection.inspect(file:url,includeRaw:true) { output.append($0) }
        XCTAssertEqual(output.map(\.metadataVersion),[0,1,1,1])
        var offset:UInt64=0
        for (i,record) in output.enumerated() {
            XCTAssertEqual(record.relayOffset,offset); offset += UInt64(frames[i].count)
            XCTAssertEqual(record.relayEnd,offset)
            XCTAssertEqual(record.kind,values[i].kind); XCTAssertEqual(record.file,values[i].file)
            XCTAssertEqual(record.observedPosition,values[i].observedPosition)
            XCTAssertEqual(record.rawBase64,raw.base64EncodedString())
        }
        XCTAssertEqual(output.count,4)
        try RelayInspection.inspect(file:url) { XCTAssertNil($0.rawBase64) }
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testInspectorRejectsEveryPartialFrameAndOversizedLengths() throws {
        let bytes=frame(try RelayMetadata(kind:"event",file:"bin",observedPosition:"4").encoded())
        let url=try temporaryFile(Data())
        try RelayInspection.inspect(file:url) { _ in XCTFail("empty file") }
        for end in 1..<bytes.count {
            try bytes.prefix(end).write(to:url)
            XCTAssertThrowsError(try RelayInspection.inspect(file:url) { _ in XCTFail("partial frame emitted") })
        }
        for lengths:(UInt32,UInt32) in [(0,3),(4097,3),(1,0),(1,16*1024*1024+1),(UInt32.max,UInt32.max)] {
            var header=Data();RelayMetadata.append(lengths.0,to:&header);RelayMetadata.append(lengths.1,to:&header)
            try header.write(to:url)
            XCTAssertThrowsError(try RelayInspection.inspect(file:url) {_ in})
        }
    }
}

extension ApplyTests {
    func testCachedTimestampPreservesExplicitDatesAndChangingInjectedClock() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        var now=Date(timeIntervalSince1970:0)
        let store=try StateStore(configuration:config(parent.appendingPathComponent("state").path),now:{now})
        for seconds in [-2208988800.0001,-0.9999,-0.0001,0,0.0001,0.9999,951782399.9999,1791000000.1234,253402300799.999] {
            now=Date(timeIntervalSince1970:seconds)
            let original=ISO8601DateFormatter();original.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            XCTAssertEqual(store.timestamp(),original.string(from:now))
            let explicit=now.addingTimeInterval(-60)
            XCTAssertEqual(store.timestamp(explicit),original.string(from:explicit))
            XCTAssertEqual(store.timestamp(),original.string(from:now))
        }
    }
}

extension ResumeTests {
    func testLegacyRelayUpgradeKeepsOffsetsAndAppendsBinaryFrames() throws {
        let path=try directory(),c=try config(path.path),groups=try helper.groups()
        do {
            let store=try StateStore(configuration:c)
            try store.bindTargetIdentity(target);try apply(groups[0],to:store);try store.stopped()
        }
        // Reconstruct a real format-5 relay and matching journal boundaries.
        var legacy=Data()
        for event in groups[0].events {
            let metadata=try JSONSerialization.data(withJSONObject:["kind":"event","file":groups[0].start.file,"observedPosition":String(event.nextPosition)],options:[.sortedKeys])
            let raw=Data(base64Encoded:event.rawBase64!)!
            RelayMetadata.append(UInt32(metadata.count),to:&legacy);RelayMetadata.append(UInt32(raw.count),to:&legacy)
            legacy += metadata; legacy += raw
        }
        let relay=path.appendingPathComponent("relay.frames")
        try legacy.write(to:relay)
        try write(path,"DROP TABLE replication_profile; DROP TABLE ddl_details; DROP TABLE compatibility; DROP TABLE ddl_skips; PRAGMA user_version=5; UPDATE state SET durable_relay_length=\(legacy.count); UPDATE groups SET relay_start=0,relay_end=\(legacy.count)")
        let db=path.appendingPathComponent("state.sqlite")
        let before=try helper.sqlite(db,"SELECT * FROM state")
        do {
            let store=try StateStore(configuration:c,initialize:false)
            XCTAssertEqual(try helper.sqlite(db,"PRAGMA user_version"),[["9"]])
            XCTAssertEqual(try helper.sqlite(db,"SELECT * FROM state"),before)
            XCTAssertEqual(try Data(contentsOf:relay),legacy)
            try store.running();try apply(groups[1],to:store);try store.stopped()
        }
        let bytes=try Data(contentsOf:relay)
        XCTAssertEqual(Data(bytes.prefix(legacy.count)),legacy)
        var versions:[Int]=[]
        try RelayInspection.inspect(file:relay) { versions.append($0.metadataVersion) }
        XCTAssertEqual(versions,Array(repeating:0,count:groups[0].events.count)+Array(repeating:1,count:groups[1].events.count))
        let resumed=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(resumed.transactions,2);XCTAssertEqual(resumed.applied,groups[1].end)
        XCTAssertEqual(try helper.sqlite(db,"SELECT relay_start FROM groups ORDER BY sequence"),[["0"],[String(legacy.count)]])
    }
}
