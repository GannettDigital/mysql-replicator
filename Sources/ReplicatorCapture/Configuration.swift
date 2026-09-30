import Foundation
import ReplicatorCodec

public struct CaptureConfiguration: Decodable {
    public struct Start: Decodable {
        public let file: String
        public let position: UInt32
        public let executedGTIDs: String
    }
    public struct Table: Decodable {
        public let database: String
        public let table: String
        public let columns: [ColumnInterpretation]
    }
    public let version: Int
    public let host: String
    public let port: Int
    public let username: String
    public let passwordEnvironment: String
    public let serverHostname: String
    public let caFile: String?
    public let serverID: UInt32
    public let sourceUUID: String
    public let mode: String
    /// Schema and GTID/position metadata must come from the same verified
    /// post-seed boundary. All DDL is rejected during this inspection window.
    public let start: Start
    public let tables: [Table]
    public let nonBlocking: Bool?
    public let stopAfterTransactions: Int?
    public let idleTimeoutSeconds: Int?
    public let maximumEventBytes: UInt32?

    public func validate() throws -> DumpStart {
        guard version == 1, !host.isEmpty, (1...65535).contains(port), !username.isEmpty, !passwordEnvironment.isEmpty,
              !serverHostname.isEmpty, serverID > 0, UUID(uuidString: sourceUUID) != nil,
              !start.file.isEmpty, !start.file.utf8.contains(0), start.file.utf8.count <= 255, start.position >= 4,
              ["file-position", "gtid"].contains(mode), !tables.isEmpty, tables.count <= 256,
              (1...300).contains(idleTimeoutSeconds ?? 15),
              (23...16*1024*1024).contains(maximumEventBytes ?? 4*1024*1024),
              stopAfterTransactions == nil || (1...1_000_000).contains(stopAfterTransactions!) else {
            throw CaptureError("invalid live capture configuration")
        }
        var seen: Set<String> = []
        for table in tables {
            guard !table.database.isEmpty, !table.table.isEmpty, !table.database.utf8.contains(0), !table.table.utf8.contains(0),
                  !table.columns.isEmpty, table.columns.count <= 256,
                  seen.insert(table.database + "\0" + table.table).inserted else { throw CaptureError("invalid/duplicate live schema entry") }
        }
        let set = try GTIDSet(start.executedGTIDs)
        return mode == "gtid" ? .gtid(set) : .position(file: start.file, position: start.position)
    }
}

public final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
