import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import ReplicatorCodec

public struct SourceObservation: Codable {
    public struct File: Codable {
        public let name: String
        public let bytes: UInt64
    }
    public let observedAt: Double
    public let executedGTIDs: String
    public let file: String
    public let position: UInt64
    public let files: [File]
    public func bytesRemaining(after coordinate: BinlogCoordinate) -> UInt64? {
        guard let start = files.firstIndex(where: { $0.name == coordinate.file }),
            let end = files.firstIndex(where: { $0.name == file }), start <= end,
            coordinate.position <= files[start].bytes
        else { return nil }
        if start == end { return position >= coordinate.position ? position - coordinate.position : 0 }
        var total = files[start].bytes - coordinate.position
        for item in files[(start + 1)..<end] {
            let next = total.addingReportingOverflow(item.bytes)
            if next.overflow { return nil }
            total = next.partialValue
        }
        let next = total.addingReportingOverflow(position)
        return next.overflow ? nil : next.partialValue
    }
}

/// Polling never touches the dump connection, target connection or SQLite.
/// Query failures leave the last successful observation with a visible error.
public final class SourceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "replicator.source-monitor")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var observation: SourceObservation?
    private var failure: String?
    public init() {}
    public func start(source: CaptureConfiguration, password: String, contract: SourceContract, interval: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let value = try Self.poll(source: source, password: password, contract: contract)
                self.lock.lock()
                self.observation = value
                self.failure = nil
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.failure = "source monitoring query failed; check connectivity and REPLICATION CLIENT permission"
                self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }
    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
    public func snapshot() -> (observation: SourceObservation?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (observation, failure)
    }
    private static func poll(source: CaptureConfiguration, password: String, contract: SourceContract) throws
        -> SourceObservation
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let connection = try MySQLConnection.connect(
            to: SocketAddress.makeAddressResolvingHost(source.host, port: source.port), username: source.username,
            database: "", password: password,
            tlsConfiguration: source.tlsConfiguration(), serverHostname: source.serverHostname,
            requireTLS: source.requireTLS, handshakeTimeout: .seconds(10), on: loop
        ).wait()
        defer { try? connection.close().wait() }
        func query(_ sql: String) throws -> [MySQLRow] {
            let timeout = loop.scheduleTask(in: .seconds(10)) { _ = connection.close() }
            defer { timeout.cancel() }
            return try connection.simpleQuery(sql).wait()
        }
        guard
            try query("SELECT @@server_uuid AS uuid").first?.column("uuid")?.string?.lowercased()
                == source.sourceUUID.lowercased()
        else { throw CaptureError("monitor source identity differs") }
        guard let status = try query(contract == .mysql57 ? "SHOW MASTER STATUS" : "SHOW BINARY LOG STATUS").first,
            let file = status.column("File")?.string, let p = status.column("Position")?.string,
            let position = UInt64(p),
            let gtids = status.column("Executed_Gtid_Set")?.string
        else { throw CaptureError("invalid source monitoring status") }
        _ = try GTIDSet(gtids)
        let rows = try query("SHOW BINARY LOGS")
        guard rows.count <= 10000 else { throw CaptureError("source monitoring inventory limit") }
        let files = try rows.map { row -> SourceObservation.File in
            guard let name = row.column("Log_name")?.string, let n = row.column("File_size")?.string,
                let bytes = UInt64(n)
            else { throw CaptureError("invalid source binlog size") }
            return .init(name: name, bytes: bytes)
        }
        return .init(
            observedAt: Date().timeIntervalSince1970, executedGTIDs: gtids, file: file, position: position, files: files
        )
    }
}
