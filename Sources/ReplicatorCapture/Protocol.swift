import Foundation
import MySQLNIO
import NIOCore
import ReplicatorCodec

public struct CaptureError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum DumpStart {
    case position(file: String, position: UInt32)
    case gtid(GTIDSet)

    func packet(serverID: UInt32, nonBlocking: Bool) throws -> MySQLPacket {
        guard serverID != 0 else { throw CaptureError("dump client server ID must be nonzero") }
        var p = MySQLPacket()
        let flags: UInt16 = nonBlocking ? 1 : 0  // No heartbeat-v2/compression negotiation.
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
            p.payload.writeInteger(UInt32(0), endianness: .little)  // source selects file
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
        if let timings {
            return try timings.measure("binlog.packet_frame") { try decodeFrame(context: context, buffer: &buffer) }
        }
        return try decodeFrame(context: context, buffer: &buffer)
    }
    private mutating func decodeFrame(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState
    {
        guard let header: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .little) else {
            return .needMoreData
        }
        let length = Int(header & 0xffffff)
        let sequence = UInt8(header >> 24)
        guard sequence == expectedSequence else { throw CaptureError("dump packet sequence mismatch") }
        guard length <= maximumMessageBytes - (pending?.readableBytes ?? 0) else {
            throw CaptureError("dump packet/message limit exceeded")
        }
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
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
        -> DecodingState
    {
        let state = try decode(context: context, buffer: &buffer)
        if state == .needMoreData && (buffer.readableBytes != 0 || pending != nil) {
            throw SourceTransportError("truncated dump packet at disconnect")
        }
        return state
    }
}

final class DumpCommand: MySQLCommand {
    let request: MySQLPacket
    let receive: (Data) throws -> Void
    let timings: StageTimings?
    init(request: MySQLPacket, timings: StageTimings? = nil, receive: @escaping (Data) throws -> Void) {
        self.request = request
        self.receive = receive
        self.timings = timings
    }
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        .init(response: [request])
    }
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if let timings {
            return try timings.measure("binlog.dump_response") {
                try handleResponse(packet: &packet, capabilities: capabilities)
            }
        }
        return try handleResponse(packet: &packet, capabilities: capabilities)
    }
    private func handleResponse(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws
        -> MySQLCommandState
    {
        if packet.isError {
            let e = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            let reason = "source dump error \(e.errorCode): \(e.sqlState ?? "") \(e.errorMessage)"
            if e.errorCode == 1053 { throw SourceTransportError(reason) }
            throw CaptureError(reason)
        }
        if packet.isEOF && packet.payload.readableBytes < 9 { return .init(done: true) }
        guard packet.payload.readInteger(as: UInt8.self) == 0, packet.payload.readableBytes >= 19 else {
            throw CaptureError("invalid dump response marker or event header")
        }
        try receive(Data(packet.payload.readableBytesView))
        return .init()
    }
}
