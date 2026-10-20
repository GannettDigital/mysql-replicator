import Foundation
import Yams

/// The shared YAML-only entry point for apply, skip and source-capture configs.
/// Schema history, journal metadata and diagnostic JSON are separate formats.
public enum ConfigurationFile {
    public static let maximumBytes = 1024 * 1024

    /// Preserve operational settings without exporting credential fields. Never
    /// read the referenced environment variables or TLS files for diagnostics.
    public static func diagnosticJSON(from url: URL) throws -> Data {
        try diagnosticJSON(from: read(from: url))
    }

    /// Use the same bytes as the running configuration, even if its file changes.
    public static func diagnosticJSON(from data: Data) throws -> Data {
        let value = try decode(DiagnosticValue.self, from: data)
        return try JSONSerialization.data(
            withJSONObject: value.redacted, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decode(type, from: read(from: url), sourceURL: url)
    }

    /// Read once so reload validation and decoding see the same file generation.
    public static func read(from url: URL) throws -> Data {
        do { return try readFile(from: url) } catch let error as ConfigurationError {
            throw error.atFile(url)
        } catch {
            // Do not include file contents or Foundation's full error context.
            throw ConfigurationError("cannot read configuration file; check that it exists and is readable").atFile(url)
        }
    }

    private static func readFile(from url: URL) throws -> Data {
        guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else {
            throw ConfigurationError(
                "configuration must be a .yaml or .yml file; convert legacy JSON configuration to YAML")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError("configuration exceeds 1 MiB") }
        return data
    }

    /// In-memory comparison only: this contains credentials and must never be
    /// logged. Every setting except the two runtime limits requires restart.
    public static func reloadIdentity(from data: Data) throws -> Data {
        guard var root = try decode(DiagnosticValue.self, from: data).value as? [String: Any],
            var source = root["source"] as? [String: Any]
        else { throw ConfigurationError("reload requires source configuration") }
        source.removeValue(forKey: "stopAfterTransactions")
        source.removeValue(forKey: "stopAfterGTIDs")
        root["source"] = source
        return try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, sourceURL: URL? = nil) throws -> T {
        do { return try decodeYAML(type, from: data) } catch let error as ConfigurationError {
            throw sourceURL.map { error.atFile($0) } ?? error
        }
    }

    private static func decodeYAML<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw ConfigurationError("configuration exceeds 1 MiB") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError("configuration must be UTF-8 YAML")
        }
        // Yams checks duplicate keys and rejects multiple documents. Fix the
        // encoding instead of allowing environment-dependent parser behavior.
        do { return try YAMLDecoder(encoding: .utf8).decode(type, from: text) } catch let error as DecodingError {
            // Yams errors may embed the whole document, including passwords.
            // Keep structural locations, never input values or source excerpts.
            let context: DecodingError.Context
            let detail: String
            var missingKey: String?
            switch error {
            case .keyNotFound(let key, let c):
                context = c
                detail = "missing setting \(key.stringValue)"
                missingKey = key.stringValue
            case .typeMismatch(_, let c):
                context = c
                detail = "wrong value type"
            case .valueNotFound(_, let c):
                context = c
                detail = "missing value"
            case .dataCorrupted(let c):
                context = c
                detail = "invalid value"
            @unknown default: throw ConfigurationError("invalid YAML configuration")
            }
            let path = (context.codingPath.map(\.stringValue) + (missingKey.map { [$0] } ?? [])).joined(separator: ".")
            if let yamlError = context.underlyingError as? YamlError {
                throw yamlDiagnostic(yamlError, keyPath: path.isEmpty ? nil : path)
            }
            throw ConfigurationError(
                "configuration \(path.isEmpty ? "root" : path): \(detail)", keyPath: path.isEmpty ? nil : path)
        } catch let error as YamlError {
            throw yamlDiagnostic(error)
        }
    }

    private static func yamlDiagnostic(_ error: YamlError, keyPath: String? = nil) -> ConfigurationError {
        let mark: Mark
        let reason: String
        switch error {
        case .duplicatedKeysInMapping(_, let context):
            mark = context.mark
            reason = "duplicate YAML key"
        case .scanner(_, _, let location, _), .parser(_, _, let location, _), .composer(_, _, let location, _):
            mark = location
            reason = "invalid YAML"
        default: return ConfigurationError("invalid YAML configuration", keyPath: keyPath)
        }
        return ConfigurationError(
            "\(reason) at line \(mark.line), column \(mark.column)", keyPath: keyPath,
            line: mark.line, column: mark.column)
    }
}

indirect enum DiagnosticValue: Decodable {
    case scalar(Any)
    case array([DiagnosticValue])
    case object([String: DiagnosticValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .scalar(NSNull())
        } else if let v = try? c.decode([String: DiagnosticValue].self) {
            self = .object(v)
        } else if let v = try? c.decode([DiagnosticValue].self) {
            self = .array(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .scalar(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .scalar(v)
        } else if let v = try? c.decode(Double.self), v.isFinite {
            self = .scalar(v)
        } else {
            self = .scalar(try c.decode(String.self))
        }
    }
    var redacted: Any {
        switch self {
        case .scalar(let value): return value
        case .array(let values): return values.map(\.redacted)
        case .object(let values):
            return values.reduce(into: [String: Any]()) { out, pair in
                let key = pair.key.lowercased().filter { $0.isLetter }
                if ["password", "secret", "token", "privatekey"].contains(where: { key.contains($0) }) {
                    out[pair.key] = "<excluded>"
                } else {
                    out[pair.key] = pair.value.redacted
                }
            }
        }
    }
    var value: Any {
        switch self {
        case .scalar(let value): return value
        case .array(let values): return values.map(\.value)
        case .object(let values): return values.mapValues(\.value)
        }
    }
}

public struct ConfigurationError: Error, CustomStringConvertible {
    public let description: String
    public let configPath: String?
    public let keyPath: String?
    public let line: Int?
    public let column: Int?
    init(_ description: String, configPath: String? = nil, keyPath: String? = nil, line: Int? = nil, column: Int? = nil)
    {
        self.description = description
        self.configPath = configPath
        self.keyPath = keyPath
        self.line = line
        self.column = column
    }
    func atFile(_ url: URL) -> Self {
        .init(description, configPath: url.path, keyPath: keyPath, line: line, column: column)
    }
}
