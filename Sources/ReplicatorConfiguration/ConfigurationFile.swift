import Foundation
import Yams

/// The shared YAML-only entry point for apply, skip and source-capture configs.
/// Schema history, journal metadata and diagnostic JSON are separate formats.
public enum ConfigurationFile {
    public static let maximumBytes = 1024 * 1024

    /// Preserve operational settings without exporting credential fields. Never
    /// read the referenced environment variables or TLS files for diagnostics.
    public static func diagnosticJSON(from url: URL) throws -> Data {
        let value=try load(DiagnosticValue.self,from:url)
        return try JSONSerialization.data(withJSONObject:value.redacted,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed])
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decode(type,from:read(from:url))
    }

    /// Read once so reload validation and decoding see the same file generation.
    public static func read(from url: URL) throws -> Data {
        guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else {
            throw ConfigurationError("configuration must be a .yaml or .yml file; convert legacy JSON configuration to YAML")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data=try file.read(upToCount:maximumBytes+1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError("configuration exceeds 1 MiB") }
        return data
    }

    /// In-memory comparison only: this contains credentials and must never be
    /// logged. Every setting except the two runtime limits requires restart.
    public static func reloadIdentity(from data: Data) throws -> Data {
        guard var root=try decode(DiagnosticValue.self,from:data).value as? [String:Any],
              var source=root["source"] as? [String:Any] else { throw ConfigurationError("reload requires source configuration") }
        source.removeValue(forKey:"stopAfterTransactions");source.removeValue(forKey:"stopAfterGTIDs")
        root["source"]=source
        return try JSONSerialization.data(withJSONObject:root,options:.sortedKeys)
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

private indirect enum DiagnosticValue: Decodable {
    case scalar(Any), array([DiagnosticValue]), object([String:DiagnosticValue])
    init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() { self = .scalar(NSNull()) }
        else if let v=try? c.decode([String:DiagnosticValue].self) { self = .object(v) }
        else if let v=try? c.decode([DiagnosticValue].self) { self = .array(v) }
        else if let v=try? c.decode(Bool.self) { self = .scalar(v) }
        else if let v=try? c.decode(Int64.self) { self = .scalar(v) }
        else if let v=try? c.decode(Double.self),v.isFinite { self = .scalar(v) }
        else { self = .scalar(try c.decode(String.self)) }
    }
    var redacted:Any {
        switch self {
        case .scalar(let value): return value
        case .array(let values): return values.map(\.redacted)
        case .object(let values):
            return values.reduce(into:[String:Any]()) { out,pair in
                let key=pair.key.lowercased().filter { $0.isLetter }
                if ["password","secret","token","privatekey"].contains(where:{key.contains($0)}) { out[pair.key]="<excluded>" }
                else { out[pair.key]=pair.value.redacted }
            }
        }
    }
    var value: Any {
        switch self {
        case .scalar(let value):return value
        case .array(let values):return values.map(\.value)
        case .object(let values):return values.mapValues(\.value)
        }
    }
}

public struct ConfigurationError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
