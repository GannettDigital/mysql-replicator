import XCTest
import NIOCore
import NIOSSL
@testable import MySQLNIO
@testable import ReplicatorCapture

final class SourceTransportTests: XCTestCase {
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
