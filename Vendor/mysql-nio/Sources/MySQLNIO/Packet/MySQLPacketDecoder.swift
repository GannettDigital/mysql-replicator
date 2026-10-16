import NIOCore
import Logging

public struct MySQLPacketDecoder: ByteToMessageDecoder {
    public typealias InboundOut = MySQLPacket

    public let sequence: MySQLPacketSequence
    let logger: Logger
    private let maximumMessageBytes: Int
    private var pending: ByteBuffer?
    private var continuationSequence: UInt8?
    
    public init(sequence: MySQLPacketSequence, logger: Logger, maximumMessageBytes: Int = MySQLPacket.maximumMessageBytes) {
        self.sequence = sequence
        self.logger = logger
        self.maximumMessageBytes = maximumMessageBytes
    }
    
    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        var copy = buffer
        guard let header = copy.readInteger(endianness: .little, as: UInt32.self) else {
            return .needMoreData
        }
        // header = 01     00 00 01
        //          <seq>  <length>
        let length = Int(header & 0x00_FF_FF_FF)
        let sequenceID = UInt8(header >> 24)
        guard length <= maximumMessageBytes - (pending?.readableBytes ?? 0),
              continuationSequence == nil || continuationSequence == sequenceID else { throw MySQLError.protocolError }
        // print("header: \(header) length: \(length) seq: \(sequenceID)")
        guard var payload = copy.readSlice(length: length) else {
            return .needMoreData
        }
        buffer = copy
        if pending != nil { pending!.writeBuffer(&payload) }
        else if length == MySQLPacket.fragmentBytes { pending = payload }
        self.sequence.current = sequenceID
        if length == MySQLPacket.fragmentBytes {
            continuationSequence = sequenceID &+ 1
            return .continue
        }
        let packet = MySQLPacket(payload: pending ?? payload)
        pending = nil; continuationSequence = nil
        self.logger.trace("MySQLPacketDecoder.decode: \(packet)")
        context.fireChannelRead(self.wrapInboundOut(packet))
        return .continue
    }
    
    public mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        let result = try decode(context:context,buffer:&buffer)
        if case .needMoreData = result, seenEOF, pending != nil || buffer.readableBytes != 0 {
            throw MySQLError.protocolError
        }
        return result
    }
}
