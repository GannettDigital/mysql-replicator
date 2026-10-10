import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO
import ReplicatorCodec

/// Socket auto-read is disabled during dumping. Only an empty consumer queue
/// requests a read; a bounded socket read may deliver multiple small packets or
/// only part of one large packet. Read completion permits the next bounded read.
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
    func readComplete() {
        condition.lock(); defer { condition.unlock() }
        readRequested = false
        condition.signal()
    }
    func push(_ data: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        guard packets.count - index < 4096, data.count <= byteLimit - bytes else {
            throw CaptureError("live packet queue limit exceeded")
        }
        packets.append(data); bytes += data.count; readRequested = false
        condition.signal()
    }
    /// Drain only frames already queued; the receiver can publish a disk batch
    /// without waiting for the source to fill an arbitrary byte threshold.
    func takeAvailable(maximumBytes: Int = 256*1024) -> [Data] {
        condition.lock(); defer { condition.unlock() }
        var result: [Data] = [], total = 0
        while index < packets.count && total < maximumBytes {
            let packet = packets[index]
            if packet.count > maximumBytes-total { break }
            index += 1; bytes -= packet.count
            result.append(packet); total += packet.count
        }
        if index == packets.count { packets = []; index = 0 }
        return result
    }
    func finish(_ result: Result<Void, Error>) {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        completion = result
        if case .failure = result { packets = []; index = 0; bytes = 0 }
        condition.broadcast()
    }
    func next(timeout: TimeInterval, cancellation: CaptureCancellation, requestRead: () -> Void, onIdle: () throws -> Void = {}) throws -> Data? {
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
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SourceTransportError("live dump idle timeout") }
            // Run consumer work without holding the socket queue mutex.
            condition.unlock()
            do { try onIdle() } catch { condition.lock(); throw error }
            condition.lock()
            if index < packets.count || completion != nil { continue }
            if !readRequested { readRequested = true; requestRead() }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
        }
    }
}

/// A read can finish before framing yields a packet. Without this notification,
/// manual reads stall on packets larger than the socket/TLS read chunk.
final class DumpReadCompletion: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let queue: PacketQueue
    init(queue: PacketQueue) { self.queue = queue }
    func channelReadComplete(context: ChannelHandlerContext) {
        queue.readComplete()
        context.fireChannelReadComplete()
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
    public var download: DownloadSnapshot? = nil
    public var stageTimings: [String:StageTimings.Sample]? = nil
    public let durableProgress = false
}

public struct CaptureCancelled: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "live inspection cancelled" }
}

public struct LiveInspectionError: Error, CustomStringConvertible {
    public let reason: String
    public let summary: LiveSummary
    public let isCancellation: Bool
    public let isRetryableSourceFailure: Bool
    init(error: Error, summary: LiveSummary) {
        self.reason = String(describing: error)
        self.summary = summary
        self.isCancellation = error is CaptureCancelled
        self.isRetryableSourceFailure = error is SourceTransportError
    }
    public var description: String { reason }
}

public enum LiveInspection {
    /// A single connection attempt. Reconnect is explicit using the last fully
    /// observed group or caller-supplied GTID set; no durable checkpoint exists.
    public static func run(configuration config: CaptureConfiguration, password: String,
                           includeRaw: Bool = false, retainRawBytes: Bool = false, cancellation: CaptureCancellation = .init(),
                           emitEvent: @escaping (LiveRecord) throws -> Void,
                           emitTransaction: @escaping (CompleteTransaction) throws -> Void,
                           resolveSchema: ((DecodedEvent, BinlogCoordinate) throws -> [ColumnInterpretation])? = nil,
                           timings: StageTimings = .init(), onIdle: @escaping () throws -> Void = {},
                           allowDDL: Bool = false, ignoreTable: ((String, String) -> Bool)? = nil,
                           sourceContract: SourceContract = .mysql84) throws -> LiveSummary {
        let start = try config.validate()
        let processor = try StreamProcessor(config: config, includeRaw: includeRaw, retainRawBytes: retainRawBytes, emitEvent: emitEvent, emitTransaction: emitTransaction, resolveSchema: resolveSchema, timings: timings, allowDDL: allowDDL, ignoreTable: ignoreTable)
        var download: DownloadSnapshot?
        func summary() -> LiveSummary {
            var result = LiveSummary(transactions: processor.transactionCount, events: processor.eventCount,
                eventBytesReceived: String(processor.receivedBytes), heartbeats: processor.heartbeatCount,
                rotationAnnouncements: processor.announcementCount, lastCompleteBoundary: processor.lastCompleteBoundary,
                pendingTransactionStart: processor.pendingTransactionStart, completeGTIDSet: processor.completeGTIDs.canonical)
            result.download = download; result.stageTimings = timings.snapshot
            return result
        }
        do {
            if processor.stopReason != nil { return summary() }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            let loop = group.next()
            let address = try sourceNetworkOperation { try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .fullVerification
            if let ca = config.caFile { tls.trustRoots = .file(ca) }
            let connection = try sourceNetworkOperation { try MySQLConnection.connect(to: address, username: config.username, database: "",
                password: password, tlsConfiguration: tls, serverHostname: config.serverHostname,
                requireTLS: true, handshakeTimeout: .seconds(10), on: loop).wait() }
            defer { try? connection.close().wait() }
            func query(_ sql: String) throws -> [MySQLRow] {
                let timeout = loop.scheduleTask(in: .seconds(10)) { _ = connection.close() }
                defer { timeout.cancel() }
                return try sourceNetworkOperation { try connection.simpleQuery(sql).wait() }
            }
            let settings = try query("SELECT @@server_uuid AS source_uuid,@@server_id AS server_id,@@GLOBAL.gtid_mode AS gtid_mode,@@GLOBAL.enforce_gtid_consistency AS gtid_consistency,@@GLOBAL.binlog_format AS binlog_format,@@GLOBAL.binlog_row_image AS row_image,@@GLOBAL.binlog_checksum AS checksum,VERSION() AS version")
            guard let row = settings.first, row.column("source_uuid")?.string?.lowercased() == config.sourceUUID.lowercased(),
                  row.column("server_id")?.string != String(config.serverID), row.column("gtid_mode")?.string == "ON",
                  row.column("gtid_consistency")?.string == "ON", row.column("binlog_format")?.string == "ROW",
                  row.column("row_image")?.string == "FULL", row.column("checksum")?.string == "CRC32",
                  row.column("version")?.string?.hasPrefix(sourceContract.rawValue) == true else {
                throw CaptureError("source identity/settings differ from the qualified MySQL \(sourceContract.rawValue) GTID-ON contract")
            }
            if ignoreTable != nil {
                let casing = try query("SELECT @@lower_case_table_names AS n")
                guard casing.first?.column("n")?.string == "0" else { throw CaptureError("wildcard filtering requires source lower_case_table_names=0") }
            }
            let ssl = try query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            guard !(ssl.first?.column("Value")?.string ?? "").isEmpty else { throw CaptureError("source connection has no TLS cipher") }
            let set = try GTIDSet(config.start.executedGTIDs)
            let covered = try query("SELECT GTID_SUBSET('\(set.canonical)',@@GLOBAL.gtid_executed) AS covered")
            guard covered.first?.column("covered")?.string == "1" else { throw CaptureError("bootstrap GTID set is not covered by this source") }
            _ = try query(sourceContract.dumpSessionSQL)
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
            let wireTimings = config.decoderProfiling == true ? StageTimings() : nil
            let strict = ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes: maximum + 1, timings:wireTimings), maximumBufferSize: maximum + 65536)
            try channel.pipeline.addHandler(strict, position: .before(old)).wait()
            try channel.pipeline.addHandler(DumpReadCompletion(queue:queue), position: .before(strict)).wait()
            try channel.pipeline.removeHandler(old).wait()
            let command = DumpCommand(request: try start.packet(serverID: config.serverID, nonBlocking: config.nonBlocking ?? false), timings:wireTimings, receive: queue.push)
            let finished = connection.send(command, logger: connection.logger)
            finished.whenComplete { queue.finish($0.mapError(sourceTransportFailure)) }
            let cache = try DownloadCache(maximumBytes:config.downloadCacheBytes ?? 256*1024*1024,
                                          maximumEventBytes:maximum)
            let receiverTimings = StageTimings()
            let stop = CaptureCancellation(parent:cancellation)
            let worker = DispatchGroup()
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            worker.enter()
            DispatchQueue(label:"mysql-replicator.download").async {
                defer { worker.leave() }
                do {
                    while let first = try receiverTimings.measure("download.socket_wait", {
                        try queue.next(timeout:TimeInterval(config.idleTimeoutSeconds ?? 15),cancellation:stop,
                                       requestRead:{ loop.execute { channel.read() } })
                    }) {
                        let frames = [first] + queue.takeAvailable(maximumBytes:max(0,256*1024-first.count))
                        try cache.append(frames,cancellation:stop,timings:receiverTimings)
                    }
                    cache.finish(.success(()),elapsed:Double(DispatchTime.now().uptimeNanoseconds-receivedAt)/1e9)
                } catch { cache.finish(.failure(error),elapsed:Double(DispatchTime.now().uptimeNanoseconds-receivedAt)/1e9) }
            }
            func joinReceiver() {
                stop.cancel(); worker.wait()
                try? connection.close().wait()
                if let wireTimings, let snapshot = try? loop.submit({ wireTimings.snapshot }).wait() { timings.merge(snapshot) }
                download = cache.snapshot
                timings.merge(receiverTimings.snapshot)
            }
            // Always join before reading the receiver's counters or deleting files.
            // Errors in transport/cache are surfaced by next(), not mistaken for EOF.
            do {
                var reachedLimit = false
                while let frames = try timings.measure("capture.wait", {
                    try cache.next(cancellation:stop,timings:timings,onIdle:{ try timings.measure("capture.idle",onIdle) })
                }) {
                    for frame in frames {
                        try cache.checkFailure()
                        try timings.measure("capture.process") { try processor.consume(frame) }
                        if processor.stopReason != nil {
                            reachedLimit = true; break
                        }
                    }
                    if reachedLimit { break }
                }
                if !reachedLimit && config.nonBlocking != true {
                    throw SourceTransportError("source ended a blocking binlog stream")
                }
                joinReceiver()
            } catch {
                stop.cancel(); cache.finish(.failure(error))
                joinReceiver()
                throw error
            }
            try cache.checkFailure(ignoringCancellation:true)
            try processor.finish()
            if processor.stopReason == nil && (config.stopAfterTransactions != nil || config.stopAfterGTIDs != nil) {
                throw CaptureError("source EOF before requested stop condition")
            }
            return summary()
        } catch { throw LiveInspectionError(error: error, summary: summary()) }
    }
}
