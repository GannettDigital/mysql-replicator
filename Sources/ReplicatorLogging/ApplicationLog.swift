import Foundation
import Logging

/// Application logs use a separate handler. Do not enable driver SQL logging.
public enum ApplicationLog {
    private static let sink = JSONLogSink { try FileHandle.standardError.write(contentsOf: $0) }
    public static let logger = Logger(label: "mysql-replicator") { _ in JSONLogHandler(sink: sink) }

    public static func configure(level: String) {
        sink.level = Logger.Level(rawValue: level) ?? .warning
    }
    /// Serialize existing JSON diagnostics with log records on the same stream.
    public static func writeDiagnostic(_ data: Data) throws { try sink.writeRecord(data) }

    /// Metadata and timers are not evaluated when this level is disabled.
    public static func measure<T>(
        _ operation: String, level: Logger.Level = .info,
        metadata: @autoclosure () -> Logger.Metadata = [:], logger: Logger = ApplicationLog.logger,
        _ body: () throws -> T
    ) rethrows -> T {
        guard logger.logLevel <= level else { return try body() }
        let details = metadata()
        logger.log(level: level, "\(operation) started", metadata: details)
        let start = DispatchTime.now().uptimeNanoseconds
        var outcome = "failed"
        defer {
            var completed = details
            completed["outcome"] = .string(outcome)
            completed["durationMilliseconds"] = .string(
                String(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6))
            logger.log(level: level, "\(operation) finished", metadata: completed)
        }
        let result = try body()
        outcome = "completed"
        return result
    }
}

/// One lock serializes records. There is no queue that can grow behind a slow sink.
/// Enabled logging is synchronous: a slow stderr consumer can slow the caller.
final class JSONLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var configuredLevel: Logger.Level?
    private let write: @Sendable (Data) throws -> Void
    init(write: @escaping @Sendable (Data) throws -> Void) { self.write = write }
    var level: Logger.Level? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredLevel
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            configuredLevel = newValue
        }
    }
    func emit(level: Logger.Level, message: String, metadata: Logger.Metadata) {
        // Call sites supply fixed messages and bounded identifiers. This list
        // prevents accidental SQL, passwords, or bound values in log metadata.
        let allowed: Set<String> = [
            "phase", "purpose", "durationMilliseconds", "outcome", "transactions", "rows", "profile", "mode",
            "transport", "file", "position", "gtid", "table", "database", "attempt", "delaySeconds",
            "filesCompleted", "filesTotal", "filesSkipped", "bytesRead", "bytesTotal", "preambleBytesRead",
            "cache", "reasonCode", "lifecycle",
        ]
        func bounded(_ text: String, bytes: Int) -> String {
            String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
        }
        let fields = metadata.filter { allowed.contains($0.key) }.sorted { $0.key < $1.key }.prefix(16)
            .reduce(into: [String: String]()) { $0[$1.key] = bounded($1.value.description, bytes: 512) }
        let record: [String: Any] = [
            "kind": "log", "level": level.rawValue, "timestamp": Date().timeIntervalSince1970,
            "message": bounded(message, bytes: 1024), "fields": fields,
        ]
        guard
            let bytes = try? JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        // A diagnostic output failure must not change the apply outcome.
        try? writeRecord(bytes + Data([10]))
    }
    func writeRecord(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(data)
    }
}

struct JSONLogHandler: LogHandler {
    let sink: JSONLogSink
    private var localLevel: Logger.Level = .warning
    init(sink: JSONLogSink) { self.sink = sink }
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level {
        get { sink.level ?? localLevel }
        set { localLevel = newValue }
    }
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String,
        function: String, line: UInt
    ) {
        sink.emit(
            level: level, message: message.description,
            metadata: self.metadata.merging(metadata ?? [:]) { _, new in new })
    }
}
