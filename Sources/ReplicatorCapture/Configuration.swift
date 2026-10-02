import Foundation
import ReplicatorCodec

public struct CaptureConfiguration: Decodable {
    public struct Start: Decodable {
        public let file: String?
        public let position: UInt32?
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
    /// post-seed boundary. Source-only inspection rejects DDL; the apply pipeline
    /// opts into ordered query groups and qualifies each DDL before execution.
    public let start: Start
    public let tables: [Table]?
    public let nonBlocking: Bool?
    public let stopAfterTransactions: Int?
    public let idleTimeoutSeconds: Int?
    public let maximumEventBytes: UInt32?

    /// Keep connection/protocol options, replacing only the authoritative boundary.
    public func resuming(file: String?, position: UInt32?, executedGTIDs: String) -> CaptureConfiguration {
        CaptureConfiguration(version:version,host:host,port:port,username:username,
            passwordEnvironment:passwordEnvironment,serverHostname:serverHostname,caFile:caFile,
            serverID:serverID,sourceUUID:sourceUUID,mode:mode,
            start:Start(file:file,position:position,executedGTIDs:executedGTIDs),tables:tables,
            nonBlocking:nonBlocking,stopAfterTransactions:stopAfterTransactions,
            idleTimeoutSeconds:idleTimeoutSeconds,maximumEventBytes:maximumEventBytes)
    }

    public func validate() throws -> DumpStart {
        guard [1,2].contains(version), !host.isEmpty, (1...65535).contains(port), !username.isEmpty, !passwordEnvironment.isEmpty,
              !serverHostname.isEmpty, serverID > 0, UUID(uuidString: sourceUUID) != nil,
              ["file-position", "gtid"].contains(mode), (version == 2 ? tables == nil : !(tables ?? []).isEmpty), (tables?.count ?? 0) <= 256,
              (1...300).contains(idleTimeoutSeconds ?? 15),
              (23...16*1024*1024).contains(maximumEventBytes ?? 4*1024*1024),
              stopAfterTransactions == nil || (1...1_000_000).contains(stopAfterTransactions!) else {
            throw CaptureError("invalid live capture configuration")
        }
        var seen: Set<String> = []
        for table in tables ?? [] {
            guard !table.database.isEmpty, !table.table.isEmpty, !table.database.utf8.contains(0), !table.table.utf8.contains(0),
                  !table.columns.isEmpty, table.columns.count <= 256,
                  seen.insert(table.database + "\0" + table.table).inserted else { throw CaptureError("invalid/duplicate live schema entry") }
        }
        if let file = start.file, let position = start.position {
            guard !file.isEmpty, !file.utf8.contains(0), file.utf8.count <= 255, position >= 4 else { throw CaptureError("invalid start coordinate") }
        } else if mode != "gtid" || start.file != nil || start.position != nil { throw CaptureError("file-position requires both fields; GTID mode permits neither") }
        let set = try GTIDSet(start.executedGTIDs)
        return mode == "gtid" ? .gtid(set) : .position(file: start.file!, position: start.position!)
    }
}

public final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let parent: CaptureCancellation?
    public init(parent: CaptureCancellation? = nil) { self.parent = parent }
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); let local = value; lock.unlock()
        return local || (parent?.isCancelled ?? false)
    }
}
