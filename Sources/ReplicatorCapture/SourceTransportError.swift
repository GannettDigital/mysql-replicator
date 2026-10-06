import Foundation
import NIOCore
import NIOSSL
import MySQLNIO
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Only source socket operations may create this error. Decoder, callback and
/// local-file failures must never be classified by their error-message text.
public struct SourceTransportError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func sourceTransportFailure(_ error: Error) -> Error {
    if error is SourceTransportError { return error }
    var retry = false
    if let mysql = error as? MySQLError {
        switch mysql {
        case .closed: retry = true
        case .server(let packet): retry = packet.errorCode == 1053 // server shutdown
        default: break
        }
    } else if let channel = error as? ChannelError {
        switch channel {
        case .connectTimeout, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof: retry = true
        default: break
        }
    } else if let io = error as? IOError {
        retry = [ECONNRESET, ECONNREFUSED, ECONNABORTED, EPIPE, ETIMEDOUT,
                 ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN].contains(io.errnoCode)
    } else if let address = error as? SocketAddressError, case .unknown = address {
        retry = true
    } else if let ssl = error as? NIOSSLError, case .uncleanShutdown = ssl {
        retry = true
    }
    return retry ? SourceTransportError(String(describing:error)) : error
}

func sourceNetworkOperation<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch { throw sourceTransportFailure(error) }
}
