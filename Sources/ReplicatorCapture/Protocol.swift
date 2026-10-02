import Foundation
import NIOCore
import MySQLNIO
import ReplicatorCodec

public struct CaptureError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Canonical, untagged GTID intervals. Bounds prevent allocation from untrusted
/// config. MySQL encodes inclusive text ends as exclusive binary ends.
public struct GTIDSet: Equatable {
    struct SID: Equatable { let uuid: UUID; var intervals: [ClosedRange<UInt64>] }
    var sids: [SID]
    public init(_ text: String) throws {
        guard text.utf8.count <= 1024 * 1024 else { throw CaptureError("GTID set exceeds 1 MiB") }
        var result: [SID] = []
        if !text.isEmpty {
            for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
                let fields = entry.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count >= 2, let uuid = UUID(uuidString: String(fields[0])),
                      !result.contains(where: { $0.uuid == uuid }), result.count < 64 else {
                    throw CaptureError("invalid, duplicate or tagged GTID SID")
                }
                var intervals: [ClosedRange<UInt64>] = []
                for field in fields.dropFirst() {
                    let bounds = field.split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(bounds.count), let low = UInt64(bounds[0]),
                          let high = UInt64(bounds.last!), low > 0, low <= high, high < UInt64(Int64.max),
                          intervals.count < 4096 else { throw CaptureError("invalid GTID interval") }
                    intervals.append(low...high)
                }
                intervals.sort { $0.lowerBound < $1.lowerBound }
                var merged: [ClosedRange<UInt64>] = []
                for range in intervals {
                    if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                        merged[merged.count-1] = last.lowerBound...max(last.upperBound, range.upperBound)
                    } else { merged.append(range) }
                }
                result.append(SID(uuid: uuid, intervals: merged))
            }
        }
        sids = result.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }
    public var isEmpty: Bool { sids.isEmpty }
    public var canonical: String {
        sids.map { sid in
            sid.uuid.uuidString.lowercased() + ":" + sid.intervals.map {
                $0.lowerBound == $0.upperBound ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound)"
            }.joined(separator: ":")
        }.joined(separator: ",")
    }
    public func contains(sid: String, sequence: String) -> Bool {
        guard let uuid = UUID(uuidString: sid), let n = UInt64(sequence) else { return false }
        return sids.first { $0.uuid == uuid }?.intervals.contains { $0.contains(n) } ?? false
    }
    public func covers(_ other: GTIDSet) -> Bool {
        other.sids.allSatisfy { required in
            guard let stored = sids.first(where: { $0.uuid == required.uuid }) else { return false }
            return required.intervals.allSatisfy { range in
                stored.intervals.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
            }
        }
    }
    public mutating func include(sid: String, sequence: String) throws {
        guard let uuid = UUID(uuidString: sid) else { throw CaptureError("invalid observed SID") }
        let components = canonical.split(separator: ",").map(String.init)
        var updated = components.map { $0.hasPrefix(uuid.uuidString.lowercased() + ":") ? $0 + ":" + sequence : $0 }
        if !sids.contains(where: { $0.uuid == uuid }) { updated.append(uuid.uuidString.lowercased() + ":" + sequence) }
        self = try GTIDSet(updated.joined(separator: ","))
    }
    func encoded() -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        buffer.writeInteger(UInt64(sids.count), endianness: .little)
        for sid in sids {
            var uuid = sid.uuid.uuid
            withUnsafeBytes(of: &uuid) { buffer.writeBytes($0) }
            buffer.writeInteger(UInt64(sid.intervals.count), endianness: .little)
            for range in sid.intervals {
                buffer.writeInteger(range.lowerBound, endianness: .little)
                buffer.writeInteger(range.upperBound + 1, endianness: .little)
            }
        }
        return buffer
    }
}

public enum DumpStart {
    case position(file: String, position: UInt32)
    case gtid(GTIDSet)

    func packet(serverID: UInt32, nonBlocking: Bool) throws -> MySQLPacket {
        guard serverID != 0 else { throw CaptureError("dump client server ID must be nonzero") }
        var p = MySQLPacket()
        let flags: UInt16 = nonBlocking ? 1 : 0 // No heartbeat-v2/compression negotiation.
        switch self {
        case .position(let file, let position):
            guard position >= 4, !file.isEmpty, file.utf8.count <= 255, !file.utf8.contains(0) else {
                throw CaptureError("invalid positional dump start")
            }
            p.payload.writeInteger(UInt8(0x12))
            p.payload.writeInteger(position, endianness: .little)
            p.payload.writeInteger(flags, endianness: .little)
            p.payload.writeInteger(serverID, endianness: .little)
            p.payload.writeString(file)
        case .gtid(let set):
            var encoded = set.encoded()
            p.payload.writeInteger(UInt8(0x1e))
            p.payload.writeInteger(flags, endianness: .little)
            p.payload.writeInteger(serverID, endianness: .little)
            p.payload.writeInteger(UInt32(0), endianness: .little) // source selects file
            p.payload.writeInteger(UInt64(4), endianness: .little)
            p.payload.writeInteger(UInt32(encoded.readableBytes), endianness: .little)
            p.payload.writeBuffer(&encoded)
        }
        return p
    }
}

/// Installed after TLS/authentication, before sending COM_BINLOG_DUMP. Sequence
/// starts at 1 and wraps at 255. Limits are checked on the header before waiting
/// for its body. One logical message may span 0xffffff-byte wire packets.
struct DumpPacketDecoder: ByteToMessageDecoder {
    typealias InboundOut = MySQLPacket
    static let fragmentBytes = 0xffffff
    let maximumMessageBytes: Int
    var timings: StageTimings? = nil
    var expectedSequence: UInt8 = 1
    var pending: ByteBuffer?
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let timings { return try timings.measure("binlog.packet_frame") { try decodeFrame(context:context,buffer:&buffer) } }
        return try decodeFrame(context:context,buffer:&buffer)
    }
    private mutating func decodeFrame(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let header: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .little) else { return .needMoreData }
        let length = Int(header & 0xffffff), sequence = UInt8(header >> 24)
        guard sequence == expectedSequence else { throw CaptureError("dump packet sequence mismatch") }
        guard length <= maximumMessageBytes - (pending?.readableBytes ?? 0) else { throw CaptureError("dump packet/message limit exceeded") }
        guard buffer.readableBytes >= 4 + length else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        var body = buffer.readSlice(length: length)!
        expectedSequence &+= 1
        if pending != nil { pending!.writeBuffer(&body) } else { pending = body }
        if length != Self.fragmentBytes {
            context.fireChannelRead(wrapInboundOut(MySQLPacket(payload: pending!)))
            pending = nil
        }
        return .continue
    }
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        let state = try decode(context: context, buffer: &buffer)
        if state == .needMoreData && (buffer.readableBytes != 0 || pending != nil) {
            throw CaptureError("truncated dump packet at disconnect")
        }
        return state
    }
}

final class DumpCommand: MySQLCommand {
    let request: MySQLPacket
    let receive: (Data) throws -> Void
    let timings: StageTimings?
    init(request: MySQLPacket, timings: StageTimings? = nil, receive: @escaping (Data) throws -> Void) {
        self.request = request; self.receive = receive; self.timings=timings
    }
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState { .init(response: [request]) }
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if let timings { return try timings.measure("binlog.dump_response") { try handleResponse(packet:&packet,capabilities:capabilities) } }
        return try handleResponse(packet:&packet,capabilities:capabilities)
    }
    private func handleResponse(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            let e = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            throw CaptureError("source dump error \(e.errorCode): \(e.sqlState ?? "") \(e.errorMessage)")
        }
        if packet.isEOF && packet.payload.readableBytes < 9 { return .init(done: true) }
        guard packet.payload.readInteger(as: UInt8.self) == 0, packet.payload.readableBytes >= 19 else {
            throw CaptureError("invalid dump response marker or event header")
        }
        try receive(Data(packet.payload.readableBytesView))
        return .init()
    }
}
