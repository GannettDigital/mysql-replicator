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
    public let passwordEnvironment: String?
    public let password: String?
    public let requireTLS: Bool
    public let serverHostname: String?
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
    public var stopAfterTransactions: Int?
    public var stopAfterGTIDs: String? = nil
    public let idleTimeoutSeconds: Int?
    public let maximumEventBytes: UInt32?
    /// Optional detailed worker-local decoder timings; absent/false keeps coarse timings only.
    public let decoderProfiling: Bool?
    /// Bounded disposable download backlog; no fsync and never a restart checkpoint.
    public let downloadCacheBytes: Int?

    /// Keep connection/protocol options, replacing only the authoritative boundary.
    public func resuming(file: String?, position: UInt32?, executedGTIDs: String, remainingTransactions: Int? = nil) -> CaptureConfiguration {
        CaptureConfiguration(version:version,host:host,port:port,username:username,
            passwordEnvironment:passwordEnvironment,password:password,requireTLS:requireTLS,serverHostname:serverHostname,caFile:caFile,
            serverID:serverID,sourceUUID:sourceUUID,mode:mode,
            start:Start(file:file,position:position,executedGTIDs:executedGTIDs),tables:tables,
            nonBlocking:nonBlocking,stopAfterTransactions:remainingTransactions ?? stopAfterTransactions,
            stopAfterGTIDs:stopAfterGTIDs,
            idleTimeoutSeconds:idleTimeoutSeconds,maximumEventBytes:maximumEventBytes,decoderProfiling:decoderProfiling,downloadCacheBytes:downloadCacheBytes)
    }

    public func validate(connection: Bool = true) throws -> DumpStart {
        _ = try StopConditions(transactions:stopAfterTransactions,gtids:stopAfterGTIDs)
        if connection { try PasswordConfiguration.validate(password:password,environmentVariable:passwordEnvironment,endpoint:"source") }
        if requireTLS {
            guard !(serverHostname ?? "").isEmpty else { throw CaptureError("source verified TLS requires serverHostname") }
        } else {
            guard serverHostname == nil && caFile == nil else { throw CaptureError("remove source serverHostname and caFile when requireTLS is false") }
        }
        guard [1,2].contains(version), !host.isEmpty, (1...65535).contains(port), !username.isEmpty,
              serverID > 0, UUID(uuidString: sourceUUID) != nil,
              ["file-position", "gtid"].contains(mode), (version == 2 ? tables == nil : !(tables ?? []).isEmpty), (tables?.count ?? 0) <= 256,
              (1...300).contains(idleTimeoutSeconds ?? 15),
              (23...16*1024*1024).contains(maximumEventBytes ?? 4*1024*1024),
              (20*1024*1024...1024*1024*1024).contains(downloadCacheBytes ?? 256*1024*1024),
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

extension CaptureConfiguration {
    enum CodingKeys: String, CodingKey {
        case version, host, port, username, passwordEnvironment, password, requireTLS, serverHostname, caFile
        case serverID, sourceUUID, mode, start, tables, nonBlocking, stopAfterTransactions, stopAfterGTIDs
        case idleTimeoutSeconds, maximumEventBytes, decoderProfiling, downloadCacheBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        passwordEnvironment = try c.decodeIfPresent(String.self, forKey: .passwordEnvironment)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        requireTLS = try c.decodeIfPresent(Bool.self, forKey: .requireTLS) ?? true
        serverHostname = try c.decodeIfPresent(String.self, forKey: .serverHostname)
        caFile = try c.decodeIfPresent(String.self, forKey: .caFile)
        serverID = try c.decode(UInt32.self, forKey: .serverID)
        sourceUUID = try c.decode(String.self, forKey: .sourceUUID)
        mode = try c.decode(String.self, forKey: .mode)
        start = try c.decode(Start.self, forKey: .start)
        tables = try c.decodeIfPresent([Table].self, forKey: .tables)
        nonBlocking = try c.decodeIfPresent(Bool.self, forKey: .nonBlocking)
        stopAfterTransactions = try c.decodeIfPresent(Int.self, forKey: .stopAfterTransactions)
        stopAfterGTIDs = try c.decodeIfPresent(String.self, forKey: .stopAfterGTIDs)
        idleTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds)
        maximumEventBytes = try c.decodeIfPresent(UInt32.self, forKey: .maximumEventBytes)
        decoderProfiling = try c.decodeIfPresent(Bool.self, forKey: .decoderProfiling)
        downloadCacheBytes = try c.decodeIfPresent(Int.self, forKey: .downloadCacheBytes)
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
