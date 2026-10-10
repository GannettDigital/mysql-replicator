import XCTest
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
@testable import ReplicatorApply

final class TargetTLSTests: XCTestCase {
    func testVerifyCAHandshakeAcceptsMissingHostnameButRejectsUntrustedCertificate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let configFile = directory.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = extensions
        prompt = no
        [dn]
        CN = target.example
        [extensions]
        basicConstraints = critical,CA:TRUE
        subjectAltName = DNS:target.example
        """.write(to:configFile,atomically:true,encoding:.utf8)
        // Fresh certificates keep this regression independent of calendar dates.
        for name in ["trusted", "unrelated"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
            process.arguments = ["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","1",
                                 "-config",configFile.path,"-keyout",directory.appendingPathComponent(name+".key").path,
                                 "-out",directory.appendingPathComponent(name+".pem").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,"could not generate TLS test certificates")
        }
        let certificate = try NIOSSLCertificate(file:directory.appendingPathComponent("trusted.pem").path,format:.pem)
        let key = try NIOSSLPrivateKey(file:directory.appendingPathComponent("trusted.key").path,format:.pem)
        let server = try NIOSSLContext(configuration:.makeServerConfiguration(certificateChain:[.certificate(certificate)],privateKey:.privateKey(key)))
        func target(mode: String? = nil, hostname: String? = nil, ca: String = "trusted") throws -> TargetConfiguration {
            var value: [String:Any] = ["host":"127.0.0.1","port":3306,"username":"test","password":"test",
                                      "nativeAutoStartDisabled":true,"caFile":directory.appendingPathComponent(ca+".pem").path]
            value["tlsVerification"] = mode; value["serverHostname"] = hostname
            let config = try JSONDecoder().decode(TargetConfiguration.self,from:JSONSerialization.data(withJSONObject:value))
            try config.validate()
            return config
        }
        try exchange(target(mode:"verify-ca"), server:server)
        try exchange(target(mode:"verify-ca",hostname:"wrong.example"), server:server)
        try exchange(target(hostname:"target.example"), server:server)
        XCTAssertThrowsError(try exchange(target(hostname:"wrong.example"), server:server))
        XCTAssertThrowsError(try exchange(target(mode:"verify-ca",ca:"unrelated"), server:server))
    }

    /// Real TLS records exchanged in memory using the production target settings.
    /// Application bytes must arrive only after a successful TLS handshake.
    private func exchange(_ target: TargetConfiguration, server context: NIOSSLContext) throws {
        let client = EmbeddedChannel(), server = EmbeddedChannel()
        defer {
            // No network remains to exchange close_notify. Advance the embedded
            // shutdown timers before finish(), which otherwise waits for a peer.
            client.close(promise:nil); server.close(promise:nil)
            client.embeddedEventLoop.advanceTime(by:.seconds(10))
            server.embeddedEventLoop.advanceTime(by:.seconds(10))
            _ = try? client.finish(); _ = try? server.finish()
        }
        let tls = try XCTUnwrap(target.tlsConfiguration())
        try server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context:context))
        try client.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context:NIOSSLContext(configuration:tls),serverHostname:target.serverHostname))
        let connected = client.connect(to:try SocketAddress(ipAddress:"127.0.0.1",port:3306))
        server.pipeline.fireChannelActive()
        let payload = ByteBuffer(string:"verified transport")
        // Queue without waiting: the handshake must complete before this write.
        client.writeAndFlush(payload, promise:nil)
        for _ in 0..<100 {
            client.embeddedEventLoop.run(); server.embeddedEventLoop.run()
            var transferred = false
            for (sender,receiver) in [(client,server),(server,client)] {
                while let record = try sender.readOutbound(as:IOData.self) {
                    _ = try receiver.writeInbound(record)
                    transferred = true
                }
            }
            try client.throwIfErrorCaught(); try server.throwIfErrorCaught()
            if let received = try server.readInbound(as:ByteBuffer.self) {
                try connected.wait()
                XCTAssertEqual(received,payload)
                return
            }
            if !transferred { break }
        }
        XCTFail("TLS handshake did not deliver application bytes")
    }
}
