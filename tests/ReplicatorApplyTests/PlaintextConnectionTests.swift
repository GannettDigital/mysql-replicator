import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture

final class PlaintextConnectionTests: XCTestCase {
    func testImmediateServerGreetingOnSeparateEventLoop() throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? clientGroup.syncShutdownGracefully()
            try? serverGroup.syncShutdownGracefully()
        }
        let disconnected = expectation(description: "all clients disconnected")
        disconnected.expectedFulfillmentCount = 200
        let server = try ServerBootstrap(group: serverGroup).childChannelInitializer { channel in
            channel.pipeline.addHandler(PlaintextHandshake(advertisesTLS: false, disconnected: disconnected))
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        for _ in 0..<200 {
            let connection = try MySQLConnection.connect(
                to: server.localAddress!, username: "test",
                database: "", password: "test", tlsConfiguration: nil,
                handshakeTimeout: .seconds(1), on: clientGroup.next()
            ).wait()
            try connection.close().wait()
        }
        wait(for: [disconnected], timeout: 2)
    }

    func testSourceAndTargetConnectAndDisconnectWithoutTLS() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        // Test a server with no TLS and one that advertises TLS. An explicit
        // opt-out must stay plaintext in both cases, including the Unix socket.
        for advertisesTLS in [false, true] {
            for endpoint in ["source", "target-tcp", "target-unix"] {
                let disconnected = expectation(description: "\(endpoint) disconnected")
                disconnected.expectedFulfillmentCount = endpoint == "source" ? 1 : 2
                let configured = endpoint == "source" ? nil : expectation(description: "metadata charset configured")
                let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("replicator-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let socket = directory.appendingPathComponent("mysql.sock").path
                let bootstrap = ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        PlaintextHandshake(
                            advertisesTLS: advertisesTLS, disconnected: disconnected, configured: configured))
                }
                let server = try
                    (endpoint == "target-unix"
                    ? bootstrap.bind(unixDomainSocketPath: socket) : bootstrap.bind(host: "127.0.0.1", port: 0)).wait()
                defer { try? server.close().wait() }
                let port = server.localAddress?.port ?? 3306
                var target: [String: Any] = [
                    "username": "test", "password": "test", "requireTLS": false, "nativeAutoStartDisabled": true,
                ]
                if endpoint == "target-unix" {
                    target["unixSocket"] = socket
                } else {
                    target["host"] = "127.0.0.1"
                    target["port"] = port
                }
                let source: [String: Any] = [
                    "version": 2, "host": "127.0.0.1", "port": port,
                    "username": "test", "password": "test", "requireTLS": false,
                    "serverID": 9100, "sourceUUID": "00000000-0000-0000-0000-000000000001",
                    "mode": "gtid", "start": ["executedGTIDs": ""],
                ]
                let data = try JSONSerialization.data(withJSONObject: [
                    "version": 2, "source": source, "target": target, "stateDirectory": "unused",
                ])
                let config = try JSONDecoder().decode(ApplyConfiguration.self, from: data)
                try config.validate()
                let connection: MySQLConnection
                var session: TargetSession?
                if endpoint == "source" {
                    let c = config.source
                    connection = try MySQLConnection.connect(
                        to: server.localAddress!, username: c.username,
                        database: "", password: c.password, tlsConfiguration: c.tlsConfiguration(),
                        serverHostname: c.serverHostname, requireTLS: c.requireTLS,
                        handshakeTimeout: .seconds(2), on: group.next()
                    ).wait()
                } else {
                    session = try TargetSession(configuration: config, password: "test")
                    connection = session!.connection
                }
                XCTAssertFalse(connection.isClosed)
                try connection.close().wait()
                XCTAssertTrue(connection.isClosed)
                session = nil
                if let configured { wait(for: [configured], timeout: 2) }
                wait(for: [disconnected], timeout: 2)
            }
        }
    }

    func testRejectedMetadataSetupClosesConnectionsAndReturnsError() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        for metadataOnly in [false, true] {
            let disconnected = expectation(description: "failed session disconnected")
            disconnected.expectedFulfillmentCount = metadataOnly ? 1 : 2
            let configured = expectation(description: "metadata charset rejected")
            let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    PlaintextHandshake(
                        advertisesTLS: false, disconnected: disconnected, configured: configured,
                        rejectSetup: true))
            }.bind(host: "127.0.0.1", port: 0).wait()
            defer { try? server.close().wait() }
            let data = Data(
                """
                {"version":2,"source":{"version":2,"host":"127.0.0.1","port":3306,
                "username":"test","password":"test","requireTLS":false,"serverID":9100,
                "sourceUUID":"00000000-0000-0000-0000-000000000001",
                "mode":"gtid","start":{"executedGTIDs":""}},
                "target":{"host":"127.0.0.1","port":\(server.localAddress!.port!),
                "username":"test","password":"test","requireTLS":false,"nativeAutoStartDisabled":true},
                "stateDirectory":"unused"}
                """.utf8)
            let config = try JSONDecoder().decode(ApplyConfiguration.self, from: data)
            let returned = expectation(description: "failed initialization returned")
            // A cleanup deadlock must fail this test without blocking XCTest.
            DispatchQueue.global().async {
                defer { returned.fulfill() }
                do {
                    _ = try TargetSession(configuration: config, password: "test", metadataOnly: metadataOnly)
                    XCTFail("metadata setup rejection was ignored")
                } catch {
                    XCTAssertTrue(error is MySQLError, "unexpected error: \(error)")
                }
            }
            wait(for: [configured, disconnected, returned], timeout: 3)
        }
    }
}

/// Minimal MySQL protocol peer on a real TCP/Unix socket. It checks that the
/// first client packet is authentication, not an SSLRequest, then accepts it.
private final class PlaintextHandshake: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let advertisesTLS: Bool
    let disconnected: XCTestExpectation
    let configured: XCTestExpectation?
    let rejectSetup: Bool
    var incoming = ByteBuffer()
    var authenticated = false
    init(
        advertisesTLS: Bool, disconnected: XCTestExpectation,
        configured: XCTestExpectation? = nil, rejectSetup: Bool = false
    ) {
        self.advertisesTLS = advertisesTLS
        self.disconnected = disconnected
        self.configured = configured
        self.rejectSetup = rejectSetup
    }
    func channelActive(context: ChannelHandlerContext) {
        let capabilities: UInt32 = 0x0008_8201 | (advertisesTLS ? 0x800 : 0)
        var payload = ByteBuffer(bytes: [10])
        payload.writeString("5.7.44")
        payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt32(1), endianness: .little)
        payload.writeBytes(Array(repeating: UInt8(1), count: 8))
        payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt16(truncatingIfNeeded: capabilities), endianness: .little)
        payload.writeInteger(UInt8(45))
        payload.writeInteger(UInt16(2), endianness: .little)
        payload.writeInteger(UInt16(capabilities >> 16), endianness: .little)
        payload.writeInteger(UInt8(21))
        payload.writeBytes(Array(repeating: UInt8(0), count: 10))
        payload.writeBytes(Array(repeating: UInt8(1), count: 12))
        payload.writeInteger(UInt8(0))
        payload.writeString("mysql_native_password")
        payload.writeInteger(UInt8(0))
        var packet = ByteBuffer(bytes: [UInt8(payload.readableBytes), 0, 0, 0])
        packet.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        incoming.writeBuffer(&bytes)
        while let header: UInt32 = incoming.getInteger(at: incoming.readerIndex, endianness: .little) {
            let size = Int(header & 0xffffff)
            guard incoming.readableBytes >= size + 4 else { return }
            incoming.moveReaderIndex(forwardBy: 4)
            var payload = incoming.readSlice(length: size)!
            if !authenticated {
                XCTAssertEqual(header >> 24, 1)
                XCTAssertGreaterThan(size, 32, "Expected an authentication response, not SSLRequest")
                let flags: UInt32 = payload.getInteger(at: payload.readerIndex, endianness: .little) ?? 0
                XCTAssertEqual(flags & 0x800, 0, "Client must not request TLS")
                XCTAssertEqual(payload.getString(at: payload.readerIndex + 32, length: 5), "test\0")
                authenticated = true
                sendOK(context: context, sequence: 2)
            } else {
                XCTAssertEqual(header >> 24, 0)
                let command = payload.readInteger(as: UInt8.self)
                if command == 1 {  // COM_QUIT has no reply.
                    context.close(promise: nil)
                    return
                }
                XCTAssertEqual(command, 3, "Expected COM_QUERY")
                XCTAssertEqual(
                    payload.readString(length: payload.readableBytes), "SET NAMES utf8mb4 COLLATE utf8mb4_bin")
                XCTAssertNotNil(configured, "Unexpected session setup query")
                configured?.fulfill()
                if rejectSetup {
                    // ER_UNKNOWN_COLLATION (1273), SQLSTATE HY000.
                    var error = ByteBuffer(bytes: [0xff, 0xf9, 0x04])
                    error.writeString("#HY000test rejects metadata setup")
                    var packet = ByteBuffer(bytes: [UInt8(error.readableBytes), 0, 0, 1])
                    packet.writeBuffer(&error)
                    context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
                } else {
                    sendOK(context: context, sequence: 1)
                }
            }
        }
    }
    private func sendOK(context: ChannelHandlerContext, sequence: UInt8) {
        context.writeAndFlush(
            wrapOutboundOut(ByteBuffer(bytes: [7, 0, 0, sequence, 0, 0, 0, 2, 0, 0, 0])), promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        disconnected.fulfill()
        context.fireChannelInactive()
    }
}
