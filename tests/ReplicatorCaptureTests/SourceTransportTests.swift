import XCTest
import NIOCore
import NIOSSL
@testable import MySQLNIO
@testable import ReplicatorCapture

final class SourceTransportTests: XCTestCase {
    func testSourceTLSDefaultsAndExplicitPlaintextSurviveResume() throws {
        func decode(_ options: [String:Any]) throws -> CaptureConfiguration {
            let base: [String:Any] = ["version":2,"host":"127.0.0.1","port":3306,
                "username":"capture","password":"secret","serverID":9100,
                "sourceUUID":"00000000-0000-0000-0000-000000000001",
                "mode":"gtid","start":["executedGTIDs":""]]
            return try JSONDecoder().decode(CaptureConfiguration.self,from:JSONSerialization.data(withJSONObject:base.merging(options){_,new in new}))
        }
        let encrypted = try decode(["serverHostname":"source"])
        _ = try encrypted.validate()
        XCTAssertTrue(encrypted.requireTLS)
        XCTAssertEqual(encrypted.tlsConfiguration()?.certificateVerification, .fullVerification)
        let plaintext = try decode(["requireTLS":false])
        _ = try plaintext.validate()
        XCTAssertNil(plaintext.tlsConfiguration())
        XCTAssertNil(plaintext.serverHostname)
        let resumed = plaintext.resuming(file:"binlog.000001",position:4,executedGTIDs:"")
        _ = try resumed.validate()
        XCTAssertFalse(resumed.requireTLS)
        XCTAssertNil(resumed.tlsConfiguration())
        for options: [String:Any] in [[:], ["serverHostname":""],
            ["requireTLS":false,"serverHostname":"source"],
            ["requireTLS":false,"caFile":"/ca.pem"]] {
            XCTAssertThrowsError(try decode(options).validate())
        }
    }

    func testOnlyTransientSourceNetworkErrorsAreRetryable() throws {
        for error: Error in [MySQLError.closed, ChannelError.eof, ChannelError.connectTimeout(.seconds(10)),
                            SocketAddressError.unknown(host:"source",port:3306), NIOSSLError.uncleanShutdown,
                            IOError(errnoCode:ECONNREFUSED,reason:"connect")] {
            XCTAssertTrue(sourceTransportFailure(error) is SourceTransportError,"\(error)")
        }
        for error: Error in [MySQLError.protocolError, MySQLError.secureConnectionRequired,
                            CaptureError("bad checksum"), CaptureError("source dump error 1236"),
                            IOError(errnoCode:ENOSPC,reason:"disk"), NIOSSLError.unableToValidateCertificate] {
            XCTAssertFalse(sourceTransportFailure(error) is SourceTransportError,"\(error)")
        }
        for (code,retry) in [(UInt16(1053),true),(1045,false),(1236,false)] {
            let packet=MySQLProtocol.ERR_Packet(errorCode:try XCTUnwrap(.init(rawValue:code)),sqlStateMarker:"#",sqlState:"HY000",errorMessage:"fixture")
            XCTAssertEqual(sourceTransportFailure(MySQLError.server(packet)) is SourceTransportError,retry)
        }
    }
    func testTruncatedSocketFrameIsRetryableButInvalidFrameIsNot() throws {
        // Existing embedded-channel wire tests exercise framing. Classification
        // must not accidentally broaden every CaptureError to a network error.
        let summary=LiveSummary(transactions:0,events:0,eventBytesReceived:"0",heartbeats:0,rotationAnnouncements:0,
            lastCompleteBoundary:nil,pendingTransactionStart:nil,completeGTIDSet:"")
        XCTAssertTrue(LiveInspectionError(error:SourceTransportError("truncated packet"),summary:summary).isRetryableSourceFailure)
        XCTAssertFalse(LiveInspectionError(error:CaptureError("bad frame length"),summary:summary).isRetryableSourceFailure)
        XCTAssertFalse(LiveInspectionError(error:CaptureCancelled(),summary:summary).isRetryableSourceFailure)
    }
}
