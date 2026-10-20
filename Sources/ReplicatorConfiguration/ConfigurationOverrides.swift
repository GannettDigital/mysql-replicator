import Foundation
import Yams

/// Overrides have no I/O. Do not log values: they can contain credentials.
public struct ConfigurationOverrides {
    private let values: [String: String]
    private let sourceOnly: Bool
    public let arguments: [String]
    public init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var clean: [String] = []
        let command = arguments.first ?? ""
        sourceOnly =
            command == "blackhole"
            || (command == "inspect"
                && arguments.contains { $0 == "--source-config" || $0.hasPrefix("--source-config=") })
        let commands = ["run", "replay", "fetch", "support-bundle", "ctl", "recovery", "skip", "blackhole", "inspect"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                clean += arguments[(index - 1)...]
                break
            }
            guard argument.hasPrefix("--") else {
                clean.append(argument)
                continue
            }
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let spelling = String(parts[0])
            let name = spelling == "config.version" ? "version" : spelling
            // --version remains the program's version command.
            guard spelling != "version", ConfigurationOptions.descriptions[name] != nil else {
                clean.append(argument)
                continue
            }
            guard commands.contains(command) else {
                throw ConfigurationError("configuration overrides require a configuration command")
            }
            let scope = name.split(separator: ".").first.map(String.init) ?? name
            if sourceOnly && scope != "source" {
                throw ConfigurationError("this command accepts only source configuration overrides")
            }
            if command == "fetch" && !["source", "archive", "profile"].contains(scope) {
                throw ConfigurationError("fetch override must be source, archive or profile")
            }
            if command == "support-bundle" && !["stateDirectory", "supportBundle", "archive"].contains(scope) {
                throw ConfigurationError("support-bundle override must be stateDirectory, supportBundle or archive")
            }
            if command == "ctl" && name != "stateDirectory" {
                throw ConfigurationError(
                    "ctl accepts only the stateDirectory override; change run/replay limits in YAML before reload")
            }
            guard values[name] == nil else { throw ConfigurationError("duplicate configuration override: \(name)") }
            guard !values.keys.contains(where: { $0.hasPrefix(name + ".") || name.hasPrefix($0 + ".") }) else {
                throw ConfigurationError("overlapping configuration overrides: \(name)")
            }
            let value: String
            if parts.count == 2 {
                value = String(parts[1])
            } else {
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ConfigurationError("missing override value for \(name)")
                }
                value = arguments[index]
                index += 1
            }
            guard value.utf8.count <= ConfigurationFile.maximumBytes else {
                throw ConfigurationError("configuration override exceeds size limit")
            }
            values[name] = value
        }
        self.values = values
        self.arguments = clean
    }
    public func read(from url: URL) throws -> Data {
        do { return try applying(to: ConfigurationFile.read(from: url)) } catch let error as ConfigurationError {
            throw error.atFile(url)
        }
    }
    public func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try ConfigurationFile.decode(type, from: read(from: url), sourceURL: url)
    }
    public func applying(to data: Data) throws -> Data {
        guard !values.isEmpty else { return data }
        guard var root = try ConfigurationFile.decode(DiagnosticValue.self, from: data).value as? [String: Any] else {
            throw ConfigurationError("configuration root must be a map")
        }
        func set(_ path: ArraySlice<String>, value: Any, in object: inout [String: Any]) throws {
            guard let key = path.first else { throw ConfigurationError("empty configuration path") }
            if path.count == 1 {
                object[key] = value
                return
            }
            if let existing = object[key], !(existing is NSNull), !(existing is [String: Any]) {
                throw ConfigurationError("configuration override parent must be a map")
            }
            var child = object[key] as? [String: Any] ?? [:]
            try set(path.dropFirst(), value: value, in: &child)
            object[key] = child
        }
        for (path, text) in values {
            // Parse a one-value document, with the same safe diagnostic handling
            // as YAML configuration. Error messages never include input values.
            let parsed: Any
            if text.isEmpty {
                parsed = ""
            } else {
                do {
                    parsed = try ConfigurationFile.decode(DiagnosticValue.self, from: Data(text.utf8)).value
                } catch is ConfigurationError {
                    // A location in this CLI value is not a location in the YAML file.
                    throw ConfigurationError("invalid YAML value for configuration override \(path)", keyPath: path)
                }
            }
            let parts = path.split(separator: ".").map(String.init)
            if sourceOnly && parts == ["source"] {
                guard let replacement = parsed as? [String: Any] else {
                    throw ConfigurationError("source override must be a map")
                }
                root = replacement
            } else {
                try set(sourceOnly ? parts.dropFirst() : parts[...], value: parsed, in: &root)
            }
        }
        let result = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        guard result.count <= ConfigurationFile.maximumBytes else {
            throw ConfigurationError("effective configuration exceeds 1 MiB")
        }
        // JSON is a YAML subset for in-memory decoding; input files stay YAML-only.
        return result
    }
}
