import Foundation
import MySQLNIO
import NIOCore
import NIOSSL
import ReplicatorCapture
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Same bounded backoff policy as the source, with an independent retry budget.
public typealias TargetReconnectPolicy = SourceReconnectPolicy

struct TargetConnectionFailure: Error, CustomStringConvertible {
    let description: String
}

func isTargetTransportFailure(_ error: Error) -> Bool {
    if error is TargetConnectionFailure { return true }
    if let e = error as? MySQLError {
        switch e {
        case .closed: return true
        case .server(let packet): return packet.errorCode == 1053
        default: return false
        }
    }
    if let e = error as? ChannelError {
        switch e {
        case .connectTimeout, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof: return true
        default: return false
        }
    }
    if let e = error as? IOError {
        return [ECONNRESET, ECONNREFUSED, ECONNABORTED, EPIPE, ETIMEDOUT,
                ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN].contains(e.errnoCode)
    }
    if let e = error as? SocketAddressError, case .unknown = e { return true }
    if let e = error as? NIOSSLError, case .uncleanShutdown = e { return true }
    return false
}

/// Set immediately before submitting mutation SQL. Even a server error may
/// represent a partial MyISAM write. No inference from affected rows on error.
struct TargetStatementTrace: Codable {
    enum Phase: String, Codable { case notIssued, possiblyExecuted, acknowledged }
    var phase: Phase = .notIssued
    var sql: String?
}

public struct TargetFailureDiagnostic: Codable {
    public struct Rows: Codable {
        let gtid: String
        let database: String
        let table: String
        let firstOrdinal: Int
        let count: Int
        let disposition: String
    }
    let reason: String
    let statement: TargetStatementTrace
    let rows: [Rows]
    let ddlGTID: String?
    let ddlSQL: String?
}

/// Separate from forced cancellation: journaled execution is allowed to drain.
struct ApplyDrainRequested: Error {}
