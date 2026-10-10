import XCTest
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
@testable import MySQLNIO
@testable import ReplicatorCapture
import ReplicatorCodec

final class CaptureTests: XCTestCase {
    let sid = "8ba09bde-bc41-11f1-8272-ba06e9024a03"
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func config(_ mode: String = "file-position", decoderProfiling: Bool? = nil, version: Int = 1) throws -> CaptureConfiguration {
        var object: [String: Any] = ["version":version,"host":"source","port":3306,"username":"capture","passwordEnvironment":"TEST_PASSWORD",
            "serverHostname":"source","serverID":9001,"sourceUUID":sid,"mode":mode,
            "start":["file":"binlog.000003","position":1589,"executedGTIDs":sid + ":1-10"],
            "tables":[["database":"poc","table":"items","columns":["signed","utf8","unsigned"]]]]
        object["decoderProfiling"] = decoderProfiling
        return try JSONDecoder().decode(CaptureConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func le<T: FixedWidthInteger>(_ n: T) -> Data { var v = n.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value >> 1 ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        }
        return value ^ 0xffffffff
    }
    func seal(_ frame: Data) -> Data { let body = Data(frame.dropLast(4)); return body + le(crc(body)) }
    func frame(_ type: UInt8, body: Data, next: UInt32, flags: UInt16 = 0) -> Data {
        let data = le(UInt32(0)) + Data([type]) + le(UInt32(8401)) + le(UInt32(body.count+23)) + le(next) + le(flags) + body
        return data + le(crc(data))
    }
    func recorded() throws -> [(UInt64,Data)] {
        let input = try Data(contentsOf: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
        var offset = 4, result: [(UInt64,Data)] = []
        while offset < input.count {
            let n = (0..<4).reduce(0) { $0 | Int(input[offset+9+$1]) << (8*$1) }
            result.append((UInt64(offset), input.subdata(in: offset..<offset+n))); offset += n
        }
        return result
    }
    func announce(_ file: String = "binlog.000003", _ position: UInt64 = 1589) -> Data {
        frame(4,body: le(position) + Data(file.utf8),next:0,flags:0x20)
    }
    func fde(_ position: UInt64 = 1589) throws -> Data {
        var data = try recorded()[0].1
        data[17] &= ~1
        if position > 4 { data.replaceSubrange(13..<17,with: le(UInt32(0))); data.replaceSubrange(71..<75,with: le(UInt32(0))) }
        return seal(data)
    }
    func processor(_ mode: String = "file-position", groups: @escaping (CompleteTransaction) throws -> Void = { _ in }) throws -> StreamProcessor {
        try StreamProcessor(config: config(mode), includeRaw: true, emitEvent: { _ in }, emitTransaction: groups)
    }
    func begin(_ processor: StreamProcessor, position: UInt64 = 1589) throws {
        try processor.consume(announce("binlog.000003",position)); try processor.consume(fde(position))
    }
    func packet(_ data: Data, sequence: UInt8) -> ByteBuffer {
        ByteBuffer(bytes: le(UInt32(data.count) | UInt32(sequence)<<24) + data)
    }
    func testDecoderProfileSeparatesProbesAndSurvivesResume() throws {
        let frames = try recorded().filter { $0.0 >= 1589 }
        let maps = UInt64(frames.filter { $0.1[4] == 19 }.count)
        for enabled in [false,true] {
            let original = try config(decoderProfiling:enabled)
            let resumed = original.resuming(file:original.start.file,position:original.start.position,executedGTIDs:original.start.executedGTIDs)
            XCTAssertEqual(resumed.decoderProfiling,enabled)
            let timings = StageTimings()
            let p = try StreamProcessor(config:resumed,includeRaw:true,emitEvent:{ _ in },emitTransaction:{ _ in },timings:timings)
            try begin(p)
            for (_,frame) in frames { try p.consume(frame) }
            try p.finish()
            XCTAssertEqual(p.transactionCount,4)
            XCTAssertEqual(timings.snapshot["capture.decode"]?.count,1+UInt64(frames.count)+maps)
            if enabled {
                XCTAssertNil(timings.snapshot["decode.call.probe_format"])
                XCTAssertNil(timings.snapshot["decode.call.probe_identity"])
                XCTAssertEqual(timings.snapshot["decode.call.probe_metadata"]?.count,maps)
                XCTAssertEqual(timings.snapshot["decode.call.event"]?.count,UInt64(frames.count))
            } else {
                XCTAssertFalse(timings.snapshot.keys.contains { $0.hasPrefix("decode.") })
            }
        }
        XCTAssertNil(try config().decoderProfiling)
    }
    func testFilteredRowsKeepGTIDBoundariesWithoutSchemaDiscoveryAndCRCStillFails() throws {
        var groups: [CompleteTransaction] = []
        let p = try StreamProcessor(config: config(), includeRaw: true, emitEvent: { _ in }, emitTransaction: { groups.append($0) }, resolveSchema: { _, _ in XCTFail("excluded schema was discovered"); return [] }, ignoreTable: { $0 == "poc" && $1 == "items" })
        try begin(p)
        for (offset, frame) in try recorded() where offset >= 1589 { try p.consume(frame) }
        try p.finish()
        XCTAssertEqual(groups.count, 4)
        let rows = groups.flatMap(\.events).filter { $0.rowFlags != nil }
        XCTAssertEqual(rows.count, 4); XCTAssertTrue(rows.allSatisfy { $0.replicationFiltered && $0.rows.isEmpty && $0.rawBase64 != nil })
        XCTAssertTrue(p.completeGTIDs.canonical.hasSuffix(":1-14"))
        let bad = try StreamProcessor(config: config(), includeRaw: false, emitEvent: { _ in }, emitTransaction: { _ in XCTFail("bad CRC completed") }, ignoreTable: { _, _ in true })
        try begin(bad)
        for (offset, frame) in try recorded() where offset >= 1589 {
            if [23,24,25,30,31,32].contains(frame[4]) {
                var damaged = frame; damaged[damaged.count-1] ^= 1
                XCTAssertThrowsError(try bad.consume(damaged)); break
            }
            try bad.consume(frame)
        }
    }
    func testPositionalDumpEncodingIsIndependentWireGolden() throws {
        let request = try DumpStart.position(file:"binlog.000003",position:1589).packet(serverID:9001,nonBlocking:true)
        let expected = Data([0x12,0x35,0x06,0,0,1,0,0x29,0x23,0,0]) + Data("binlog.000003".utf8)
        XCTAssertEqual(Data(request.payload.readableBytesView), expected)
        XCTAssertThrowsError(try DumpStart.position(file:"x",position:3).packet(serverID:1,nonBlocking:false))
        XCTAssertThrowsError(try DumpStart.position(file:"x",position:4).packet(serverID:0,nonBlocking:false))
    }
    func testGTIDEncodingMergesIntervalsAndUsesExclusiveEnds() throws {
        let set = try GTIDSet("00000000-0000-0000-0000-000000000001:5:1-3:3-4:9")
        XCTAssertEqual(set.canonical,"00000000-0000-0000-0000-000000000001:1-5:9")
        var expected = le(UInt64(1))
        expected.append(Data(repeating:0,count:15)); expected.append(1)
        for n: UInt64 in [2,1,6,9,10] { expected.append(le(n)) }
        XCTAssertEqual(Data(set.encoded().readableBytesView),expected)
        let request = try DumpStart.gtid(set).packet(serverID:9001,nonBlocking:false)
        let header = Data([0x1e,0,0,0x29,0x23,0,0]) + le(UInt32(0)) + le(UInt64(4)) + le(UInt32(expected.count))
        XCTAssertEqual(Data(request.payload.readableBytesView),header+expected)
        for bad in [sid+":0",sid+":2-1",sid+":9223372036854775807",sid+":tag:1",sid+":1,"+sid+":2",sid+":",",",sid+":1-"] {
            XCTAssertThrowsError(try GTIDSet(bad),bad)
        }
    }
    func testPacketFramingSplitsCoalescesAndWrapsSequence() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:100)))
        defer { _ = try? channel.finish() }
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        for n in 1...260 { var p = packet(Data([UInt8(n & 255)]), sequence: UInt8(n & 255)); buffer.writeBuffer(&p) }
        while buffer.readableBytes > 0 { _ = try channel.writeInbound(buffer.readSlice(length:min(3,buffer.readableBytes))!) }
        for n in 1...260 {
            let p = try XCTUnwrap(channel.readInbound(as:MySQLPacket.self))
            XCTAssertEqual(Array(p.payload.readableBytesView),[UInt8(n & 255)])
        }
        XCTAssertNil(try channel.readInbound(as:MySQLPacket.self))
    }
    func testPartialSocketReadAllowsAnotherReadWithoutACompletePacket() throws {
        let queue=PacketQueue(byteLimit:100)
        let channel=EmbeddedChannel(handlers:[DumpReadCompletion(queue:queue),ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:100))])
        defer { _ = try? channel.finish() }
        let worker=DispatchQueue(label:"partial-dump-read-test")
        var requests=0
        let received=try queue.next(timeout:2,cancellation:.init(),requestRead:{
            requests += 1
            if requests == 1 { worker.async { queue.readComplete() } }
            else { worker.async { try! queue.push(Data([42])) } }
        })
        XCTAssertEqual(requests,2)
        XCTAssertEqual(received,Data([42]))
        // The notification handler also forwards fragmented bytes unchanged.
        var wire=packet(Data([1,2,3]),sequence:1)
        _ = try channel.writeInbound(wire.readSlice(length:5)!)
        XCTAssertNil(try channel.readInbound(as:MySQLPacket.self))
        _ = try channel.writeInbound(wire)
        XCTAssertEqual(Array(try XCTUnwrap(channel.readInbound(as:MySQLPacket.self)).payload.readableBytesView),[1,2,3])
    }
    func testMultipartPacketRequiresFinalShortOrEmptyPacket() throws {
        let n = DumpPacketDecoder.fragmentBytes
        let channel = EmbeddedChannel(handler:ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:n+2)))
        _ = try channel.writeInbound(packet(Data(repeating:0xab,count:n),sequence:1))
        XCTAssertNil(try channel.readInbound(as:MySQLPacket.self))
        _ = try channel.writeInbound(packet(Data(),sequence:2))
        let message = try XCTUnwrap(channel.readInbound(as:MySQLPacket.self))
        XCTAssertEqual(message.payload.readableBytes,n)
        XCTAssertTrue(message.payload.readableBytesView.allSatisfy { $0 == 0xab })
        _ = try channel.finish()
    }
    func testBadSequenceOversizeAndTruncatedPacketsFail() throws {
        for bytes in [packet(Data([1]),sequence:2), ByteBuffer(bytes:le(UInt32(101)|(1<<24)))] {
            let channel = EmbeddedChannel(handler:ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:100)))
            XCTAssertThrowsError(try channel.writeInbound(bytes)) { XCTAssertFalse($0 is SourceTransportError) }; _ = try? channel.finish()
        }
        for prefix in [Data([5,0]),Data([5,0,0,1,9])] {
            let channel = EmbeddedChannel(handler:ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:100)))
            _ = try channel.writeInbound(ByteBuffer(bytes:prefix))
            XCTAssertThrowsError(try channel.finish()) { XCTAssertTrue($0 is SourceTransportError) }
        }
    }
    func testDumpMarkersEOFAndServerErrors() throws {
        var received: [Data] = []
        let request = try DumpStart.position(file:"x",position:4).packet(serverID:1,nonBlocking:true)
        let command = DumpCommand(request:request) { received.append($0) }
        var good = MySQLPacket(payload:ByteBuffer(bytes:Data([0])+frame(3,body:Data(),next:27)))
        _ = try command.handle(packet:&good,capabilities:[])
        XCTAssertEqual(received.count,1)
        var bad = MySQLPacket(payload:ByteBuffer(bytes:[0xfb,1,2]))
        XCTAssertThrowsError(try command.handle(packet:&bad,capabilities:[]))
        var error = MySQLPacket(payload:ByteBuffer(bytes:Data([0xff,0xd4,0x04])+Data("#HY000purged history".utf8)))
        XCTAssertThrowsError(try command.handle(packet:&error,capabilities:[.CLIENT_PROTOCOL_41])) { XCTAssertTrue(String(describing:$0).contains("purged history")) }
        var eof = MySQLPacket(payload:ByteBuffer(bytes:[0xfe,0,0,0,0]))
        let done = try command.handle(packet:&eof,capabilities:[])
        XCTAssertTrue(done.done)
    }
    func testPositionalAndGTIDLiveGroupsMatchOfflineExactly() throws {
        var offline: [CompleteTransaction] = []
        let history = try JSONDecoder().decode(SchemaHistory.self,from:Data(contentsOf:root.appendingPathComponent("tests/ReplicatorCodecTests/Schema/source-positive.json")))
        try Inspection.inspectTransactions(file:root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),sourceFile:"binlog.000003",history:history) {
            if $0.start.position >= 1589 { offline.append($0) }
        }
        for mode in ["file-position","gtid"] {
            var groups: [CompleteTransaction] = []
            let p = try processor(mode) { groups.append($0) }
            try begin(p,position:mode == "gtid" ? 4 : 1589)
            if mode == "gtid" {
                try p.consume(recorded()[1].1)
                try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1589))
            }
            for (at,event) in try recorded() where at >= 1589 && at < 2841 { try p.consume(event) }
            try p.finish()
            // Includes exact values, identities, original headers, hashes and
            // source positions. Raw opt-in must match on both sides.
            let actual = try JSONSerialization.jsonObject(with:JSONEncoder().encode(groups)) as! [[String:Any]]
            let expected = try JSONSerialization.jsonObject(with:JSONEncoder().encode(offline)) as! [[String:Any]]
            var clean = actual
            for i in clean.indices {
                var events = clean[i]["events"] as! [[String:Any]]
                for j in events.indices { events[j].removeValue(forKey:"rawBase64") }
                clean[i]["events"] = events
            }
            XCTAssertEqual(clean as NSArray,expected as NSArray)
            XCTAssertEqual(p.completeGTIDs.canonical,sid+":1-14")
        }
    }
    func testTruncatedGroupAndHeartbeatCannotCompleteIt() throws {
        let p = try processor("gtid"); try begin(p,position:4)
        try p.consume(recorded()[1].1)
        try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1589))
        for (at,event) in try recorded() where at >= 1589 && at < 1854 { try p.consume(event) }
        XCTAssertEqual(p.transactionCount,0); XCTAssertEqual(p.completeGTIDs.canonical,sid+":1-10")
        XCTAssertThrowsError(try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1885)))
        XCTAssertThrowsError(try p.finish())
    }
    func testArtificialRotationAndHeartbeatAreNotPhysicalProgress() throws {
        let p = try processor(); try begin(p)
        let boundary = p.lastCompleteBoundary
        try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1589))
        XCTAssertEqual(p.lastCompleteBoundary,boundary); XCTAssertEqual(p.eventCount,0)
        XCTAssertThrowsError(try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1590)))
        let other = try processor(); try begin(other)
        var corrupt = frame(27,body:Data("binlog.000003".utf8),next:1589); corrupt[22] ^= 1
        XCTAssertThrowsError(try other.consume(corrupt))
        XCTAssertThrowsError(try processor().consume(fde()))
        XCTAssertThrowsError(try processor().consume(announce("wrong.000003",1589)))
    }
    func testPhysicalRotationRequiresMatchingAnnouncementAndRebuildsContext() throws {
        let p = try processor(); try begin(p)
        for (at,event) in try recorded() where at >= 1589 { try p.consume(event) }
        XCTAssertEqual(p.lastCompleteBoundary,BinlogCoordinate(file:"binlog.000004",position:4))
        try p.consume(announce("binlog.000004",4)); try p.consume(fde(4)); try p.finish()
        XCTAssertEqual(p.lastCompleteBoundary,BinlogCoordinate(file:"binlog.000004",position:127))
        XCTAssertThrowsError(try p.consume(announce("binlog.000005",4)))
    }
    func testRestartFileTransitionWithoutPhysicalRotateRequiresCompleteAdjacentFile() throws {
        for stopped in [false,true] {
            let p=try processor(); try begin(p)
            for (at,event) in try recorded() where at >= 1589 && at < 1885 { try p.consume(event) }
            if stopped { try p.consume(frame(3,body:Data(),next:1908)) }
            let applied=p.completeGTIDs
            try p.consume(announce("binlog.000004",4)); try p.consume(fde(4)); try p.finish()
            XCTAssertEqual(p.completeGTIDs,applied)
            XCTAssertEqual(p.transactionCount,1)
        }
        for (file,position) in [("binlog.000005",UInt64(4)),("other.000004",4),("binlog.000004",100)] {
            let p=try processor(); try begin(p)
            XCTAssertThrowsError(try p.consume(announce(file,position)))
        }
        let partial=try processor(); try begin(partial)
        try partial.consume(recorded().first { $0.0 == 1589 }!.1)
        XCTAssertThrowsError(try partial.consume(announce("binlog.000004",4)))
    }
    func testGTIDCoverageRequiresWholeIntervalsAndMatchingSIDs() throws {
        let set=try GTIDSet(sid+":1-10:12-20")
        XCTAssertTrue(try set.covers(GTIDSet("")))
        XCTAssertTrue(try set.covers(GTIDSet(sid+":2-9:15-18")))
        XCTAssertFalse(try set.covers(GTIDSet(sid+":1-12")))
        XCTAssertFalse(try set.covers(GTIDSet("00000000-0000-0000-0000-000000000001:1")))
    }
    func testQueueIsBoundedCancellationAndFailureDiscardQueuedData() throws {
        let q = PacketQueue(byteLimit:3), cancellation = CaptureCancellation()
        try q.push(Data([1,2])); XCTAssertThrowsError(try q.push(Data([3,4])))
        q.finish(.failure(CaptureError("cut")))
        XCTAssertThrowsError(try q.next(timeout:1,cancellation:cancellation,requestRead:{}))
        let cancelled = PacketQueue(byteLimit:3); cancellation.cancel()
        XCTAssertThrowsError(try cancelled.next(timeout:1,cancellation:cancellation,requestRead:{})) {
            XCTAssertTrue($0 is CaptureCancelled)
        }
        // A concurrent stop must not turn a known transport failure into success.
        XCTAssertThrowsError(try q.next(timeout:1,cancellation:cancellation,requestRead:{})) {
            XCTAssertFalse($0 is CaptureCancelled)
            XCTAssertEqual(String(describing:$0),"cut")
        }
        let done = PacketQueue(byteLimit:3); try done.push(Data([1])); done.finish(.success(()))
        XCTAssertEqual(try done.next(timeout:1,cancellation:.init(),requestRead:{}),Data([1]))
        XCTAssertNil(try done.next(timeout:1,cancellation:.init(),requestRead:{}))
    }
    func testWireDisconnectMidGroupPublishesNothingAndExplicitReplayRecovers() throws {
        let events = try recorded().filter { $0.0 >= 1589 && $0.0 < 1885 }.map { $0.1 }
        var groups: [CompleteTransaction] = []
        let interrupted = try processor { groups.append($0) }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:4096)))
        let command = DumpCommand(request:try DumpStart.position(file:"binlog.000003",position:1589).packet(serverID:9001,nonBlocking:false), receive:interrupted.consume)
        let wire = [announce(),try fde()] + Array(events.dropLast())
        for (index,event) in wire.enumerated() {
            var encoded = packet(Data([0]) + event,sequence:UInt8(index+1))
            while encoded.readableBytes > 0 {
                _ = try channel.writeInbound(encoded.readSlice(length:min(7,encoded.readableBytes))!)
                while var decoded = try channel.readInbound(as:MySQLPacket.self) { _ = try command.handle(packet:&decoded,capabilities:[]) }
            }
        }
        _ = try channel.finish()
        XCTAssertThrowsError(try interrupted.finish())
        XCTAssertTrue(groups.isEmpty)
        XCTAssertEqual(interrupted.completeGTIDs.canonical,sid+":1-10")
        XCTAssertEqual(interrupted.pendingTransactionStart,BinlogCoordinate(file:"binlog.000003",position:1589))
        let replay = try processor { groups.append($0) }; try begin(replay)
        for event in events { try replay.consume(event) }
        try replay.finish()
        XCTAssertEqual(groups.count,1); XCTAssertEqual(replay.completeGTIDs.canonical,sid+":1-11")
    }
    func testFrozenSchemaRejectsHistoryBeforeBootstrap() throws {
        let p = try processor("gtid"); try begin(p,position:4)
        try p.consume(recorded()[1].1)
        // This earlier GTID is already excluded by the supplied seed boundary.
        XCTAssertThrowsError(try p.consume(recorded()[2].1))
        XCTAssertEqual(p.transactionCount,0)
    }

    func testRequiredTLSRejectsBeforeAuthenticationOutput() throws {
        let channel = EmbeddedChannel()
        let done = channel.eventLoop.makePromise(of:Void.self)
        var failure: Error?
        done.futureResult.whenFailure { failure = $0 }
        let handler = MySQLConnectionHandler(logger:.init(label:"test"),state:.handshake(.init(requireTLS:true,
            username:"test",database:"",password:"never-send",tlsConfiguration:.makeClientConfiguration(),serverHostname:"source",done:done)),sequence:.init())
        try channel.pipeline.addHandler(handler).wait()
        // Minimal protocol-41 handshake with no SSL capability.
        var payload = ByteBuffer(bytes:[10]); payload.writeString("8.4.8"); payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt32(1),endianness:.little); payload.writeBytes(Array(repeating:UInt8(1),count:8))
        payload.writeInteger(UInt8(0)); payload.writeInteger(UInt16(0x0201),endianness:.little)
        _ = try channel.writeInbound(MySQLPacket(payload:payload))
        XCTAssertTrue(String(describing:failure).contains("TLS is required"))
        XCTAssertNil(try channel.readOutbound(as:MySQLPacket.self))
        _ = try? channel.finish()
    }
    func testHandshakeTimeoutClosesSilentServerConnection() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads:1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group:group).childChannelInitializer { $0.eventLoop.makeSucceededFuture(()) }.bind(host:"127.0.0.1",port:0).wait()
        defer { try? server.close().wait() }
        XCTAssertThrowsError(try MySQLConnection.connect(to:server.localAddress!,username:"x",database:"",requireTLS:true,
            handshakeTimeout:.milliseconds(30),on:group.next()).wait())
    }
}
