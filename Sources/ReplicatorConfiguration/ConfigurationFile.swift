import Foundation
import Yams

/// The shared YAML-only entry point for apply, skip and source-capture configs.
/// Schema history, journal metadata and diagnostic JSON are separate formats.
public enum ConfigurationFile {
    public static let maximumBytes = 1024 * 1024

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else {
            throw ConfigurationError("configuration must be a .yaml or .yml file; convert legacy JSON configuration to YAML")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(type, from: file.read(upToCount: maximumBytes + 1) ?? Data())
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw ConfigurationError("configuration exceeds 1 MiB") }
        guard let text = String(data: data, encoding: .utf8) else { throw ConfigurationError("configuration must be UTF-8 YAML") }
        // Yams checks duplicate keys and rejects multiple documents. Fix the
        // encoding instead of allowing environment-dependent parser behavior.
        do { return try YAMLDecoder(encoding: .utf8).decode(type, from: text) }
        catch let error as DecodingError {
            // Yams errors may embed the whole document, including passwords.
            // Keep structural locations, never input values or source excerpts.
            let context: DecodingError.Context
            let detail: String
            switch error {
            case .keyNotFound(let key,let c): context=c; detail="missing setting \(key.stringValue)"
            case .typeMismatch(_,let c): context=c; detail="wrong value type"
            case .valueNotFound(_,let c): context=c; detail="missing value"
            case .dataCorrupted(let c): context=c; detail="invalid value"
            @unknown default: throw ConfigurationError("invalid YAML configuration")
            }
            if let yamlError=context.underlyingError as? YamlError {
                switch yamlError {
                case .duplicatedKeysInMapping(_,let c):
                    throw ConfigurationError("duplicate YAML key at line \(c.mark.line), column \(c.mark.column)")
                case .scanner(_,_,let mark,_), .parser(_,_,let mark,_), .composer(_,_,let mark,_):
                    throw ConfigurationError("invalid YAML at line \(mark.line), column \(mark.column)")
                default: throw ConfigurationError("invalid YAML configuration")
                }
            }
            let path=context.codingPath.map(\.stringValue).joined(separator:".")
            throw ConfigurationError("configuration \(path.isEmpty ? "root" : path): \(detail)")
        }
    }
}

public struct ConfigurationError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
