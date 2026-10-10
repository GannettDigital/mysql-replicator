import XCTest
import Foundation
import NIOCore
import NIOPosix
import MySQLNIO
@testable import ReplicatorApply
@testable import ReplicatorCapture

final class PlaintextConnectionTests: XCTestCase {
    func testSourceAndTargetConnectAndDisconnectWithoutTLS() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        // Test a server with no TLS and one that advertises TLS. An explicit
        // opt-out must stay plaintext in both cases, including the Unix socket.
        for advertisesTLS in [false, true] {
            for endpoint in ["source", "target-tcp", "target-unix"] {
                let disconnected = expectation(description: "\(endpoint) disconnected")
                let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("replicator-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let socket = directory.appendingPathComponent("mysql.sock").path
                let bootstrap = ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandler(PlaintextHandshake(advertisesTLS: advertisesTLS, disconnected: disconnected))
                }
                let server = try (endpoint == "target-unix" ? bootstrap.bind(unixDomainSocketPath: socket) : bootstrap.bind(host: "127.0.0.1", port: 0)).wait()
                defer { try? server.close().wait() }
                let port = server.localAddress?.port ?? 3306
                var target: [String:Any] = ["username":"test", "password":"test", "requireTLS":false, "nativeAutoStartDisabled":true]
                if endpoint == "target-unix" { target["unixSocket"] = socket }
                else { target["host"] = "127.0.0.1"; target["port"] = port }
                let source: [String:Any] = ["version":2,"host":"127.0.0.1","port":port,
                    "username":"test","password":"test","requireTLS":false,
                    "serverID":9100,"sourceUUID":"00000000-0000-0000-0000-000000000001",
                    "mode":"gtid","start":["executedGTIDs":""]]
                let data = try JSONSerialization.data(withJSONObject: ["version":2,"source":source,"target":target,"stateDirectory":"unused"])
                let config = try JSONDecoder().decode(ApplyConfiguration.self, from: data)
                try config.validate()
                let connection: MySQLConnection
                var session: TargetSession?
                if endpoint == "source" {
                    let c = config.source
                    connection = try MySQLConnection.connect(to: server.localAddress!, username:c.username,
                        database:"",password:c.password,tlsConfiguration:c.tlsConfiguration(),
                        serverHostname:c.serverHostname,requireTLS:c.requireTLS,
                        handshakeTimeout:.seconds(2),on:group.next()).wait()
                } else {
                    session = try TargetSession(configuration:config,password:"test")
                    connection = session!.connection
                }
                XCTAssertFalse(connection.isClosed)
                try connection.close().wait()
                XCTAssertTrue(connection.isClosed)
                session = nil
                wait(for: [disconnected], timeout: 2)
            }
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
    var incoming = ByteBuffer()
    var authenticated = false
    init(advertisesTLS: Bool, disconnected: XCTestExpectation) {
        self.advertisesTLS = advertisesTLS; self.disconnected = disconnected
    }
    func channelActive(context: ChannelHandlerContext) {
        let capabilities: UInt32 = 0x00088201 | (advertisesTLS ? 0x800 : 0)
        var payload = ByteBuffer(bytes: [10])
        payload.writeString("5.7.44"); payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt32(1), endianness:.little)
        payload.writeBytes(Array(repeating:UInt8(1), count:8)); payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt16(truncatingIfNeeded:capabilities), endianness:.little)
        payload.writeInteger(UInt8(45)); payload.writeInteger(UInt16(2), endianness:.little)
        payload.writeInteger(UInt16(capabilities >> 16), endianness:.little)
        payload.writeInteger(UInt8(21)); payload.writeBytes(Array(repeating:UInt8(0), count:10))
        payload.writeBytes(Array(repeating:UInt8(1), count:12)); payload.writeInteger(UInt8(0))
        payload.writeString("mysql_native_password"); payload.writeInteger(UInt8(0))
        var packet = ByteBuffer(bytes:[UInt8(payload.readableBytes),0,0,0])
        packet.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(packet), promise:nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data); incoming.writeBuffer(&bytes)
        guard !authenticated, let header: UInt32 = incoming.getInteger(at:0, endianness:.little) else { return }
        let size = Int(header & 0xffffff)
        guard incoming.readableBytes >= size + 4 else { return }
        XCTAssertEqual(header >> 24, 1)
        XCTAssertGreaterThan(size, 32, "Expected an authentication response, not SSLRequest")
        let flags: UInt32 = incoming.getInteger(at:4, endianness:.little) ?? 0
        XCTAssertEqual(flags & 0x800, 0, "Client must not request TLS")
        XCTAssertEqual(incoming.getString(at:36, length:5), "test\0")
        authenticated = true
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes:[7,0,0,2,0,0,0,2,0,0,0])), promise:nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        disconnected.fulfill()
        context.fireChannelInactive()
    }
}
