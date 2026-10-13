import Logging
import NIOCore

public final class MySQLPacketEncoder: MessageToByteEncoder {
    public typealias OutboundIn = MySQLPacket
    
    public let sequence: MySQLPacketSequence
    let logger: Logger

    public init(sequence: MySQLPacketSequence, logger: Logger) {
        self.sequence = sequence
        self.logger = logger
    }
    
    public func encode(data: MySQLPacket, out: inout ByteBuffer) throws {
        var packet = data
        self.logger.trace("MySQLPacketDecoder.encode: \(packet)")
        guard packet.payload.readableBytes <= MySQLPacket.maximumMessageBytes else { throw MySQLError.protocolError }
        // A full-size fragment requires a continuation, including an empty
        // final fragment when the message is an exact multiple of 0xffffff.
        while true {
            let length = min(packet.payload.readableBytes, MySQLPacket.fragmentBytes)
            out.writeInteger(UInt8(length & 0xFF))
            out.writeInteger(UInt8(length >> 8 & 0xFF))
            out.writeInteger(UInt8(length >> 16 & 0xFF))
            out.writeInteger(self.sequence.next())
            var fragment = packet.payload.readSlice(length:length)!
            out.writeBuffer(&fragment)
            if length < MySQLPacket.fragmentBytes { break }
        }
    }
}
