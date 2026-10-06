import Foundation
import Yams
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct LabError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LabError(message) }
}

public func writeJSON(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

public func runID() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8).lowercased()
}

public struct CommandResult {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// File-backed output avoids pipe deadlocks. Subprocesses receive argument arrays,
/// never interpolated shell commands. Every command has a bounded lifetime.
public final class ProcessRunner {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func run(_ arguments: [String], environment: [String: String] = [:],
                    timeout: TimeInterval = 120, checked: Bool = true, onOutput: ((Data) -> Void)? = nil) throws -> CommandResult {
        try require(!arguments.isEmpty, "empty command")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replicator-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        let liveOut = try FileHandle(forReadingFrom:outURL), liveErr = try FileHandle(forReadingFrom:errURL)
        defer { try? liveOut.close(); try? liveErr.close() }
        func drain() throws {
            guard let onOutput else { return }
            for file in [liveOut,liveErr] {
                // Bound each poll so a chatty child cannot starve the timeout.
                if let data = try file.read(upToCount:64*1024), !data.isEmpty { onOutput(data) }
            }
        }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var finished = false
        repeat {
            finished = completion.wait(timeout:.now() + 0.1) == .success
            try drain()
        } while !finished && ProcessInfo.processInfo.systemUptime < deadline
        if !finished {
            process.terminate()
            if completion.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try drain()
            throw LabError("command timed out: \(arguments.first!)")
        }
        let outSize = try outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let errSize = try errURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(outSize <= 128 * 1024 * 1024 && errSize <= 128 * 1024 * 1024, "command output exceeds lab limit")
        if let onOutput {
            for file in [liveOut,liveErr] {
                if let rest = try file.readToEnd(), !rest.isEmpty { onOutput(rest) }
            }
        }
        let result = CommandResult(stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL), status: process.terminationStatus)
        if checked && result.status != 0 {
            throw LabError("command \(arguments.first!) exited \(result.status): " + String(decoding: result.stderr.suffix(16_384), as: UTF8.self))
        }
        return result
    }
}

/// Generated runtime configuration uses the same YAML format as operator files.
func writeYAML(_ object: Any, to url: URL) throws {
    try Yams.dump(object: object, sortKeys: true).write(to: url, atomically: true, encoding: .utf8)
}
func readYAML(_ url: URL) throws -> [String: Any] {
    guard let object = try Yams.load(yaml: String(contentsOf: url, encoding: .utf8)) as? [String: Any] else {
        throw LabError("configuration must be a YAML mapping")
    }
    return object
}
