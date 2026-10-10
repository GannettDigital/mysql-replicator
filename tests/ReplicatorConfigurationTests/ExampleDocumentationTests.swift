import XCTest
import Foundation
import ReplicatorConfiguration
import ReplicatorCapture
@testable import ReplicatorApply

extension ConfigurationFileTests {
    func testFullExampleDocumentsEveryConfigurationOption() throws {
        let config = try ConfigurationFile.decode(ApplyConfiguration.self, from: Data(example().utf8))
        // Supply optional sections so reflection also visits their fields. Field
        // names come from the models, not a second hand-maintained option list.
        let optionalSections: [String:Any] = [
            "compatibility": CompatibilityPolicy(), "ddlPolicy": DDLPolicy(),
            "storage": StoragePolicy(), "batch": BatchPolicy(),
            "sourceReconnect": SourceReconnectPolicy(), "targetReconnect": TargetReconnectPolicy(),
            "skipErrors": SkipErrorPolicy()
        ]
        var expected = Set<String>()
        func inspect(_ value: Any, path: String = "") {
            var mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let child = mirror.children.first { mirror = Mirror(reflecting: child.value) }
                else if let sample = optionalSections[path] { mirror = Mirror(reflecting: sample) }
                else {
                    // Unknown optional section types must get a specimen above.
                    // This prevents a newly added section from hiding its fields.
                    let type = String(describing: mirror.subjectType)
                    let scalarTypes = ["String", "Bool", "Int", "Int64", "UInt32", "UInt64", "ReplicationProfile"]
                    XCTAssertTrue(scalarTypes.contains { type == "Optional<\($0)>" } || type.hasPrefix("Optional<Array<"),
                                  "Add a specimen for optional section \(path): \(type)")
                    return
                }
            }
            guard mirror.displayStyle == .struct else { return }
            for child in mirror.children {
                guard let key = child.label else { continue }
                let name = path.isEmpty ? key : path + "." + key
                // Removed v1 schema manifests are rejected in the shared v2 config.
                if name == "tables" || name == "source.tables" { continue }
                expected.insert(name)
                inspect(child.value, path: name)
            }
        }
        inspect(config)
        let bundle = try ConfigurationFile.decode(SupportBundleConfiguration.self, from: Data("""
        stateDirectory: ./state
        archive:
          directory: ./binlogs
        supportBundle:
          output: ./support.tar
        """.utf8))
        inspect(bundle)

        let documented = documentedOptions(in: try example())
        XCTAssertEqual(expected.subtracting(documented.keys), [], "Options missing from apply.example.yaml")
        // Maps have user-defined keys, not additional configuration properties.
        XCTAssertEqual(Set(documented.keys).subtracting(expected), [], "Unknown options in apply.example.yaml")
        for key in expected {
            XCTAssertFalse((documented[key] ?? "").isEmpty, "Add a description for \(key) in apply.example.yaml")
        }
    }

    /// Read active and commented option lines, retaining YAML nesting. Each
    /// option needs an inline description or a preceding prose comment.
    private func documentedOptions(in text: String) -> [String:String] {
        let pattern = try! NSRegularExpression(pattern: #"^( *)([a-z][A-Za-z0-9]*):(?:\s|$)"#)
        var parents: [(indent: Int, key: String)] = []
        var result: [String:String] = [:]
        var precedingComment = ""
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if let hash = line.firstIndex(of: "#"), line[..<hash].allSatisfy({ $0 == " " }) {
                line.remove(at: hash)
                if line.indices.contains(hash), line[hash] == " " { line.remove(at: hash) }
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let indentation = Range(match.range(at: 1), in: line),
                  let keyRange = Range(match.range(at: 2), in: line) else {
                precedingComment = raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? line.trimmingCharacters(in: .whitespaces) : ""
                continue
            }
            let indent = line[indentation].count, key = String(line[keyRange])
            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            let path = (parents.map(\.key) + [key]).joined(separator: ".")
            let comment = line.firstIndex(of: "#").map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? precedingComment
            if result[path] == nil || !comment.isEmpty { result[path] = comment }
            parents.append((indent, key))
            precedingComment = ""
        }
        return result
    }
}
