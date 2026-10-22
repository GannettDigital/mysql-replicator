import Foundation

/// Select files once. Reload reads the same paths, even if environment variables
/// change or a new default file appears. CLI parsing itself does not read files.
public struct ConfigurationSources {
    public static let environmentKey = "MYSQL_REPLICATOR_CONFIG"
    public static let systemPath = "/etc/mysql-replicator/apply.yaml"
    public let files: [URL]

    /// An explicit path wins over the environment. Either selects one file only.
    /// Without either, system settings are followed by user settings.
    public init(
        path: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
        systemFile: URL = URL(fileURLWithPath: systemPath)
    ) throws {
        if let selected = path ?? environment[Self.environmentKey] {
            guard !selected.isEmpty else {
                throw ConfigurationError(
                    "configuration path is empty; use --config FILE.yaml or set \(Self.environmentKey)")
            }
            files = [URL(fileURLWithPath: selected).standardizedFileURL]
            return
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let candidates = [systemFile, URL(fileURLWithPath: home).appendingPathComponent(".mysql-replicator.yaml")]
        var selected: [URL] = []
        for file in candidates {
            do {
                // Do not treat an access error as an absent file.
                _ = try FileManager.default.attributesOfItem(atPath: file.path)
                selected.append(file.standardizedFileURL)
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
                {
                    continue
                }
                throw ConfigurationError("cannot inspect default configuration file; check access").atFile(file)
            }
        }
        guard !selected.isEmpty else {
            throw ConfigurationError(
                "no configuration file found; use --config FILE.yaml, set \(Self.environmentKey), or create \(systemFile.path) or ~/.mysql-replicator.yaml"
            )
        }
        files = selected
    }

    // A type error in a merged document can refer to either file. Do not assign
    // a false file/line location. Syntax errors retain their original file.
    public var sourceURL: URL? { files.count == 1 ? files[0] : nil }

    public func read(overrides: ConfigurationOverrides) throws -> Data {
        if let sourceURL { return try overrides.read(from: sourceURL) }
        var merged: [String: Any] = [:]
        for file in files {
            let data = try ConfigurationFile.read(from: file)
            guard
                let map = try ConfigurationFile.decode(DiagnosticValue.self, from: data, sourceURL: file).value
                    as? [String: Any]
            else { throw ConfigurationError("configuration root must be a map").atFile(file) }
            merged = Self.merge(merged, map)
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)
        guard data.count <= ConfigurationFile.maximumBytes else {
            throw ConfigurationError("merged configuration exceeds 1 MiB")
        }
        return try overrides.applying(to: data)
    }

    public func load<T: Decodable>(_ type: T.Type, overrides: ConfigurationOverrides) throws -> T {
        try ConfigurationFile.decode(type, from: read(overrides: overrides), sourceURL: sourceURL)
    }

    private static func merge(_ earlier: [String: Any], _ later: [String: Any]) -> [String: Any] {
        var result = earlier
        for (key, value) in later {
            if let oldMap = result[key] as? [String: Any], let newMap = value as? [String: Any] {
                result[key] = merge(oldMap, newMap)
            } else {
                // Arrays, scalars, and explicit null replace the earlier value.
                result[key] = value
            }
        }
        return result
    }
}
