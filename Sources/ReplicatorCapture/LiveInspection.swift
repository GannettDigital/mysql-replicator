import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO
import ReplicatorCodec

/// Socket auto-read is disabled during dumping. Only an empty consumer queue
/// requests a read; a bounded socket read may deliver multiple small packets.
/// No decoding, SQL wait, stdout write or blocking lock wait runs on NIO loops.
final class PacketQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var packets: [Data] = []
    private var index = 0
    private var bytes = 0
    private var completion: Result<Void, Error>?
    private var readRequested = false
    let byteLimit: Int
    init(byteLimit: Int) { self.byteLimit = byteLimit }
    func push(_ data: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        guard packets.count - index < 4096, data.count <= byteLimit - bytes else {
            throw CaptureError("live packet queue limit exceeded")
        }
        packets.append(data); bytes += data.count; readRequested = false
        condition.signal()
    }
    func finish(_ result: Result<Void, Error>) {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        completion = result
        if case .failure = result { packets = []; index = 0; bytes = 0 }
        condition.broadcast()
    }
    func next(timeout: TimeInterval, cancellation: CaptureCancellation, requestRead: () -> Void) throws -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        condition.lock(); defer { condition.unlock() }
        while true {
            // A known transport failure must not be hidden by a concurrent stop.
            if case .failure(let error) = completion { throw error }
            if cancellation.isCancelled { throw CaptureCancelled() }
            if index < packets.count {
                let packet = packets[index]; index += 1; bytes -= packet.count
                if index == packets.count { packets = []; index = 0 }
                return packet
            }
            if let completion { try completion.get(); return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError("live dump idle timeout") }
            if !readRequested { readRequested = true; requestRead() }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
        }
    }
}

public struct LiveSummary: Encodable {
    public let kind = "live_capture_summary"
    public let transactions: Int
    public let events: Int
    public let eventBytesReceived: String
    public let heartbeats: Int
    public let rotationAnnouncements: Int
    public let lastCompleteBoundary: BinlogCoordinate?
    public let pendingTransactionStart: BinlogCoordinate?
    public let completeGTIDSet: String
    public let durableProgress = false
}

struct CaptureCancelled: Error, CustomStringConvertible {
    var description: String { "live inspection cancelled" }
}

public struct LiveInspectionError: Error, CustomStringConvertible {
    public let reason: String
    public let summary: LiveSummary
    public let isCancellation: Bool
    init(error: Error, summary: LiveSummary) {
        self.reason = String(describing: error)
        self.summary = summary
        self.isCancellation = error is CaptureCancelled
    }
    public var description: String { reason }
}

public enum LiveInspection {
    /// A single connection attempt. Reconnect is explicit using the last fully
    /// observed group or caller-supplied GTID set; no durable checkpoint exists.
    public static func run(configuration config: CaptureConfiguration, password: String,
                           includeRaw: Bool = false, cancellation: CaptureCancellation = .init(),
                           emitEvent: @escaping (LiveRecord) throws -> Void,
                           emitTransaction: @escaping (CompleteTransaction) throws -> Void,
                           resolveSchema: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])? = nil,
                           allowDDL: Bool = false) throws -> LiveSummary {
        let start = try config.validate()
        let processor = try StreamProcessor(config: config, includeRaw: includeRaw, emitEvent: emitEvent, emitTransaction: emitTransaction, resolveSchema: resolveSchema, allowDDL: allowDDL)
        func summary() -> LiveSummary {
            LiveSummary(transactions: processor.transactionCount, events: processor.eventCount,
                eventBytesReceived: String(processor.receivedBytes), heartbeats: processor.heartbeatCount,
                rotationAnnouncements: processor.announcementCount, lastCompleteBoundary: processor.lastCompleteBoundary,
                pendingTransactionStart: processor.pendingTransactionStart, completeGTIDSet: processor.completeGTIDs.canonical)
        }
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            let loop = group.next()
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .fullVerification
            if let ca = config.caFile { tls.trustRoots = .file(ca) }
            let connection = try MySQLConnection.connect(to: address, username: config.username, database: "",
                password: password, tlsConfiguration: tls, serverHostname: config.serverHostname,
                requireTLS: true, handshakeTimeout: .seconds(10), on: loop).wait()
            defer { try? connection.close().wait() }
            func query(_ sql: String) throws -> [MySQLRow] {
                let timeout = loop.scheduleTask(in: .seconds(10)) { _ = connection.close() }
                defer { timeout.cancel() }
                return try connection.simpleQuery(sql).wait()
            }
            let settings = try query("SELECT @@server_uuid AS source_uuid,@@server_id AS server_id,@@GLOBAL.gtid_mode AS gtid_mode,@@GLOBAL.enforce_gtid_consistency AS gtid_consistency,@@GLOBAL.binlog_format AS binlog_format,@@GLOBAL.binlog_row_image AS row_image,@@GLOBAL.binlog_checksum AS checksum,VERSION() AS version")
            guard let row = settings.first, row.column("source_uuid")?.string?.lowercased() == config.sourceUUID.lowercased(),
                  row.column("server_id")?.string != String(config.serverID), row.column("gtid_mode")?.string == "ON",
                  row.column("gtid_consistency")?.string == "ON", row.column("binlog_format")?.string == "ROW",
                  row.column("row_image")?.string == "FULL", row.column("checksum")?.string == "CRC32",
                  row.column("version")?.string?.hasPrefix("8.4.") == true else {
                throw CaptureError("source identity/settings differ from the qualified MySQL 8.4 GTID-ON contract")
            }
            let ssl = try query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            guard !(ssl.first?.column("Value")?.string ?? "").isEmpty else { throw CaptureError("source connection has no TLS cipher") }
            let set = try GTIDSet(config.start.executedGTIDs)
            let covered = try query("SELECT GTID_SUBSET('\(set.canonical)',@@GLOBAL.gtid_executed) AS covered")
            guard covered.first?.column("covered")?.string == "1" else { throw CaptureError("bootstrap GTID set is not covered by this source") }
            _ = try query("SET @source_binlog_checksum='CRC32',@source_heartbeat_period=1000000000")
            if cancellation.isCancelled { throw CaptureCancelled() }

            let maximum = Int(config.maximumEventBytes ?? 4*1024*1024)
            let queue = PacketQueue(byteLimit: maximum + 256*1024)
            // Replace only dump framing; retain the upstream TLS, authentication,
            // packet encoder, command lifecycle and socket implementation.
            let channel = connection.channel
            try channel.setOption(ChannelOptions.autoRead, value: false).wait()
            try channel.setOption(ChannelOptions.maxMessagesPerRead, value: 1).wait()
            try channel.setOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64*1024)).wait()
            let old = try channel.pipeline.handler(type: ByteToMessageHandler<MySQLPacketDecoder>.self).wait()
            let strict = ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes: maximum + 1), maximumBufferSize: maximum + 65536)
            try channel.pipeline.addHandler(strict, position: .before(old)).wait()
            try channel.pipeline.removeHandler(old).wait()
            let command = DumpCommand(request: try start.packet(serverID: config.serverID, nonBlocking: config.nonBlocking ?? false), receive: queue.push)
            let finished = connection.send(command, logger: connection.logger)
            finished.whenComplete { queue.finish($0) }
            while let frame = try queue.next(timeout: TimeInterval(config.idleTimeoutSeconds ?? 15), cancellation: cancellation,
                                             requestRead: { loop.execute { channel.read() } }) {
                try processor.consume(frame)
                if let limit = config.stopAfterTransactions, processor.transactionCount == limit {
                    try processor.finish()
                    return summary()
                }
            }
            try processor.finish()
            if let required = config.stopAfterTransactions, processor.transactionCount < required {
                throw CaptureError("source EOF before requested transaction count")
            }
            return summary()
        } catch { throw LiveInspectionError(error: error, summary: summary()) }
    }
}
