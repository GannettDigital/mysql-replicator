import Foundation
import NIOSSL
import ReplicatorCapture
import ReplicatorCodec

/// A passed check describes only the operation named in that check.
public final class ValidationReport: Encodable, Error {
    public struct Check: Encodable {
        public let name: String
        public let status: String
        public let detail: String
        public let nextStep: String?
    }
    public let kind = "validation"
    public let mode: String
    public private(set) var checks: [Check] = []
    public var ok: Bool { !checks.contains { $0.status == "failed" } }
    private var secrets: [String] = []
    enum CodingKeys: String, CodingKey { case kind, mode, checks, ok }
    public init(mode: String) { self.mode = mode }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(mode, forKey: .mode)
        try c.encode(checks, forKey: .checks)
        try c.encode(ok, forKey: .ok)
    }
    func redact(_ secret: String?) {
        if let secret, !secret.isEmpty { secrets.append(secret) }
    }
    private func safe(_ detail: String) -> String {
        secrets.sorted { $0.count > $1.count }.reduce(detail) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
    public func failed(_ name: String, detail: String, nextStep: String) {
        checks.append(.init(name: name, status: "failed", detail: safe(detail), nextStep: nextStep))
    }
    func unchecked(_ name: String, _ detail: String, nextStep: String? = nil) {
        checks.append(.init(name: name, status: "notChecked", detail: detail, nextStep: nextStep))
    }
    @discardableResult
    func check(_ name: String, nextStep: String, _ operation: () throws -> String) -> Bool {
        do {
            checks.append(.init(name: name, status: "passed", detail: try operation(), nextStep: nil))
            return true
        } catch {
            failed(name, detail: String(describing: error), nextStep: nextStep)
            return false
        }
    }
}

/// No StateStore, relay, control server, writer lock, or data mutation is opened here.
public enum ApplyValidation {
    public static func run(configuration: ApplyConfiguration, offline: Bool, archive: ArchiveConfiguration? = nil)
        -> ValidationReport
    {
        run(configuration: configuration, offline: offline, archive: archive, connections: .live)
    }

    struct Connections {
        var target: (ApplyConfiguration, String, ValidationReport) -> Void
        var source: (CaptureConfiguration, String, SourceContract) throws -> Void
        static let live = Connections(target: TargetReadiness.inspect, source: SourceReadiness.inspect)
    }

    static func run(
        configuration c: ApplyConfiguration, offline: Bool, archive: ArchiveConfiguration?,
        connections: Connections
    ) -> ValidationReport {
        let report = ValidationReport(mode: offline ? "replay" : "run")
        report.redact(c.target.password)
        report.redact(c.source.password)
        guard
            report.check(
                "configuration", nextStep: "Correct the named setting. Use config-help for its type and limits.",
                {
                    try c.validate(offline: offline)
                    if offline {
                        try require(c.source.mode == "gtid", "offline replay requires GTID positioning")
                        try require(archive != nil, "replay requires archive configuration")
                        try archive?.validate()
                    }
                    return "Profile, filters, limits, and connection settings are valid."
                })
        else { return report }
        var targetPassword = ""
        var sourcePassword = ""
        report.check("target.credentials", nextStep: "Set the target password or its configured environment variable.")
        {
            targetPassword = try PasswordConfiguration.resolve(
                password: c.target.password,
                environmentVariable: c.target.passwordEnvironment, endpoint: "target")
            report.redact(targetPassword)
            return "Target credentials resolved."
        }
        if offline {
            report.unchecked(
                "source.connection", "Replay does not resolve source credentials or connect to the source.")
        } else {
            report.check(
                "source.credentials", nextStep: "Set the source password or its configured environment variable."
            ) {
                sourcePassword = try PasswordConfiguration.resolve(
                    password: c.source.password,
                    environmentVariable: c.source.passwordEnvironment, endpoint: "source")
                report.redact(sourcePassword)
                return "Source credentials resolved."
            }
        }
        report.check("target.tls", nextStep: "Correct target TLS settings and the CA file, if configured.") {
            if let tls = c.target.tlsConfiguration() { _ = try NIOSSLContext(configuration: tls) }
            return c.target.requireTLS ? "TLS context and trust roots loaded." : "TLS is disabled by configuration."
        }
        if !offline {
            report.check("source.tls", nextStep: "Correct source TLS settings and the CA file, if configured.") {
                if let tls = ConnectionTLS.configuration(
                    required: c.source.requireTLS,
                    verification: c.source.tlsVerification, caFile: c.source.caFile)
                {
                    _ = try NIOSSLContext(configuration: tls)
                }
                return c.source.requireTLS ? "TLS context and trust roots loaded." : "TLS is disabled by configuration."
            }
        }
        report.check(
            "state.path",
            nextStep: "Use a writable local state path with enough free space and a short control socket path."
        ) {
            let path = URL(fileURLWithPath: c.stateDirectory).standardizedFileURL
            try require(!c.stateDirectory.utf8.contains(0), "stateDirectory contains NUL")
            try require(
                path.appendingPathComponent("control.sock").path.utf8.count <= 103,
                "stateDirectory is too long for control.sock (maximum socket path: 103 bytes)")
            return try ValidationDirectory.probe(path, minimumFreeBytes: c.policy.minimumFreeDiskBytes)
        }
        if c.supportBundle?.onBlocked == true, let directory = c.supportBundle?.directory {
            report.check(
                "supportBundle.path", nextStep: "Use a writable support bundle directory outside the state directory."
            ) {
                try ValidationDirectory.probe(
                    URL(fileURLWithPath: directory).standardizedFileURL,
                    minimumFreeBytes: c.policy.minimumFreeDiskBytes)
            }
        }
        guard report.ok else { return report }
        connections.target(c, targetPassword, report)
        guard report.ok else {
            report.unchecked(
                offline ? "archive" : "source.readiness", "Not checked because target readiness failed.",
                nextStep: "Correct the target failure and run validation again.")
            return report
        }
        if offline, let archive {
            report.check(
                "archive", nextStep: "Check the archive path, file order, source identity, baseline, and byte limit."
            ) {
                let replay = try ArchiveReplay(
                    configuration: archive, source: c.source, contract: c.replicationProfile.sourceContract)
                var bytesRead: UInt64 = 0
                let baseline = try GTIDSet(c.source.start.executedGTIDs)
                for (index, file) in replay.manifest.files.enumerated() {
                    let preamble = try ArchivePreamble.read(
                        file: URL(fileURLWithPath: archive.directory).appendingPathComponent(file.name),
                        maximumEventBytes: c.source.eventByteLimit)
                    try require(
                        preamble.sourceVersion.hasPrefix(c.replicationProfile.sourceContract.rawValue),
                        "archive file version differs from profile: \(file.name)")
                    if index == 0 {
                        try require(
                            try baseline.covers(GTIDSet(preamble.previousGTIDs)),
                            "configured baseline does not cover first Previous_gtids; check source.start.executedGTIDs")
                    }
                    bytesRead += preamble.bytesRead
                }
                let bytes = replay.manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
                return
                    "\(replay.manifest.files.count) files; \(bytes) bytes; \(bytesRead) preamble bytes read. All selected files are readable."
            }
            report.unchecked(
                "archive.events",
                "Event CRCs after the preambles, transaction history, and stop GTID availability need the full replay scan."
            )
        } else {
            report.check(
                "source.readiness",
                nextStep: "Check source access, TLS, UUID, version, binlog settings, and REPLICATION CLIENT permission."
            ) {
                try connections.source(c.source, sourcePassword, c.replicationProfile.sourceContract)
                return "Source contract, configured baseline, TLS session, and binlog inventory access passed."
            }
            report.unchecked(
                "source.dump",
                "No binlog stream was requested. REPLICATION SLAVE permission and retained event history are not proved.",
                nextStep: "Check source grants and binlog retention before run.")
        }
        report.unchecked(
            "state.resume",
            "Existing SQLite state was not opened. Identity, checkpoint, and pending-intent checks run at startup.")
        return report
    }
}

/// Probe inside a private directory. Do not create the configured state directory.
enum ValidationDirectory {
    static func probe(_ destination: URL, minimumFreeBytes: Int64) throws -> String {
        let fm = FileManager.default
        var parent = destination
        var isDirectory: ObjCBool = false
        while !fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            let next = parent.deletingLastPathComponent()
            try require(next.path != parent.path, "no existing parent for stateDirectory")
            parent = next
        }
        try require(isDirectory.boolValue, "state path or its parent is not a directory")
        let attributes = try fm.attributesOfFileSystem(forPath: parent.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
        try require(free >= minimumFreeBytes, "filesystem free space is below storage.minimumFreeDiskBytes")
        let temporary = parent.appendingPathComponent(".replicator-validate-" + UUID().uuidString)
        try fm.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("probe")
        try require(
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
            "cannot create private probe file")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("probe".utf8))
        try handle.synchronize()
        try handle.close()
        let renamed = temporary.appendingPathComponent("renamed")
        try fm.moveItem(at: file, to: renamed)
        try require(try Data(contentsOf: renamed) == Data("probe".utf8), "filesystem probe read differs")
        try fm.removeItem(at: temporary)
        return
            "Create, write, sync, rename, read, and remove passed at \(parent.path); \(free) bytes free. This does not prove crash durability."
    }
}
