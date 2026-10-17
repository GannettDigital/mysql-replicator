import Logging
import MySQLNIO
import NIOCore
import NIOEmbedded
import XCTest

final class LargePacketTests: XCTestCase {
    private let logger = Logger(label: "large-packet-test")
    func testFragmentBoundariesRoundTripAndSequenceWrap() throws {
        let boundary = MySQLPacket.fragmentBytes
        for size in [0, boundary - 1, boundary, boundary + 1, boundary * 2] {
            let sequence = MySQLPacketSequence()
            sequence.current = 254
            let encoder = MySQLPacketEncoder(sequence: sequence, logger: logger)
            let payload = ByteBuffer(bytes: Array(repeating: UInt8(0xa5), count: size))
            var encoded = ByteBuffer()
            try encoder.encode(data: MySQLPacket(payload: payload), out: &encoded)
            var headers = encoded
            var lengths: [Int] = []
            var sequences: [UInt8] = []
            while headers.readableBytes > 0 {
                let header = headers.readInteger(endianness: .little, as: UInt32.self)!
                let length = Int(header & 0xffffff)
                lengths.append(length)
                sequences.append(UInt8(header >> 24))
                headers.moveReaderIndex(forwardBy: length)
            }
            XCTAssertEqual(lengths.reduce(0, +), size)
            XCTAssertLessThan(lengths.last!, boundary)
            XCTAssertEqual(sequences, lengths.indices.map { UInt8(truncatingIfNeeded: 255 + $0) })
            let readSequence = MySQLPacketSequence()
            let channel = EmbeddedChannel(
                handler: ByteToMessageHandler(MySQLPacketDecoder(sequence: readSequence, logger: logger)))
            // Feed partial headers and bodies; no logical message before the end.
            while encoded.readableBytes > 0 {
                let chunk = encoded.readSlice(length: min(65537, encoded.readableBytes))!
                try channel.writeInbound(chunk)
                if encoded.readableBytes > 0 { XCTAssertNil(try channel.readInbound(as: MySQLPacket.self)) }
            }
            XCTAssertEqual(try channel.readInbound(as: MySQLPacket.self)?.payload, payload)
            XCTAssertEqual(readSequence.current, sequences.last)
            XCTAssertTrue(try channel.finish().isClean)
        }
    }
    func testSizeAndSequenceErrorsAndTruncation() throws {
        let bounded = EmbeddedChannel(
            handler: ByteToMessageHandler(MySQLPacketDecoder(sequence: .init(), logger: logger, maximumMessageBytes: 8))
        )
        var header = ByteBuffer()
        header.writeInteger(UInt32(9), endianness: .little)
        XCTAssertThrowsError(try bounded.writeInbound(header))
        _ = try? bounded.finish()
        for suffix in [Data([0, 0, 0, 7]), Data()] {
            let channel = EmbeddedChannel(
                handler: ByteToMessageHandler(MySQLPacketDecoder(sequence: .init(), logger: logger)))
            var fragment = ByteBuffer()
            fragment.writeInteger(UInt32(0xffffff), endianness: .little)
            fragment.writeRepeatingByte(1, count: MySQLPacket.fragmentBytes)
            try channel.writeInbound(fragment)
            XCTAssertNil(try channel.readInbound(as: MySQLPacket.self))
            if suffix.isEmpty {
                XCTAssertThrowsError(try channel.finish())
            } else {
                XCTAssertThrowsError(try channel.writeInbound(ByteBuffer(bytes: suffix)))
                _ = try? channel.finish()
            }
        }
    }
    func testExecuteSizeIncludesLengthPrefixesNullMapAndTypes() throws {
        for length in [0, 250, 251, 65535, 65536, 16_777_215, 16_777_216] {
            let values: [MySQLData] = [
                .null, .init(int: 42),
                .init(type: .blob, buffer: ByteBuffer(bytes: Array(repeating: UInt8(7), count: length))),
            ]
            var packet = MySQLPacket()
            let execute = MySQLProtocol.COM_STMT_EXECUTE(statementID: 1, flags: [], values: values)
            try execute.encode(to: &packet, capabilities: [])
            XCTAssertEqual(MySQLProtocol.COM_STMT_EXECUTE.payloadSize(values: values), packet.payload.readableBytes)
        }
    }
}
