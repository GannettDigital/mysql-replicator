import Foundation
import CoreFoundation

/// The deliberately small JSON Schema vocabulary used by the committed catalog.
/// Unsupported keywords fail closed; this is not a general JSON Schema engine.
enum DDLCoverageSchema {
    private static let keywords: Set<String> = ["$schema", "$id", "title", "description", "$defs", "$ref", "type", "properties", "required", "additionalProperties", "items", "enum", "minItems", "uniqueItems", "minLength", "pattern", "minimum"]

    static func validate(_ value: Any, schema: [String: Any]) throws {
        try audit(schema, root: schema, depth: 0)
        try check(value, schema: schema, root: schema, path: "$", depth: 0)
    }
    private static func reference(_ ref: String, root: [String: Any]) throws -> [String: Any] {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "#", parts[1] == "$defs",
              let definitions = root["$defs"] as? [String: Any], let schema = definitions[String(parts[2])] as? [String: Any] else {
            throw LabError("unsupported or missing schema reference: \(ref)")
        }
        return schema
    }
    private static func audit(_ schema: [String: Any], root: [String: Any], depth: Int) throws {
        try require(depth < 32, "catalog schema nesting/reference limit exceeded")
        try require(Set(schema.keys).isSubset(of: keywords), "unknown catalog schema keyword: \(Set(schema.keys).subtracting(keywords).sorted())")
        for key in ["$schema", "$id", "title", "description", "$ref", "type", "pattern"] where schema[key] != nil {
            try require(schema[key] is String, "invalid schema keyword type: \(key)")
        }
        for key in ["minItems", "minLength", "minimum"] where schema[key] != nil {
            guard let number = schema[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue else { throw LabError("invalid schema numeric keyword: \(key)") }
        }
        for key in ["uniqueItems", "additionalProperties"] where schema[key] != nil {
            guard let number = schema[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw LabError("invalid schema boolean keyword: \(key)") }
        }
        if schema["$defs"] != nil { try require(schema["$defs"] is [String: Any], "invalid schema definitions") }
        if let choices = schema["enum"] { try require((choices as? [Any])?.isEmpty == false, "invalid schema enum") }
        if let definitions = schema["$defs"] as? [String: Any] {
            for key in definitions.keys.sorted() {
                guard let child = definitions[key] as? [String: Any] else { throw LabError("invalid schema definition: \(key)") }
                try audit(child, root: root, depth: depth + 1)
            }
        }
        if let ref = schema["$ref"] as? String {
            try require(schema.count == 1, "catalog schema references cannot have sibling keywords")
            try audit(reference(ref, root: root), root: root, depth: depth + 1)
            return
        }
        guard let type = schema["type"] as? String, ["object", "array", "string", "integer", "boolean"].contains(type) else { throw LabError("catalog schema requires a supported type") }
        let perType: [String: Set<String>] = ["object": ["properties", "required", "additionalProperties"], "array": ["items", "minItems", "uniqueItems"], "string": ["minLength", "pattern"], "integer": ["minimum"], "boolean": []]
        let shared: Set<String> = ["$schema", "$id", "title", "description", "$defs", "type", "enum"]
        try require(Set(schema.keys).isSubset(of: shared.union(perType[type]!)), "schema keywords incompatible with type \(type)")
        if type == "object" {
            guard let properties = schema["properties"] as? [String: Any], let required = schema["required"] as? [String], schema["additionalProperties"] as? Bool == false else { throw LabError("catalog object schema must declare properties, required and additionalProperties=false") }
            try require(Set(required).count == required.count && Set(required).isSubset(of: Set(properties.keys)), "invalid schema required keys")
            for key in properties.keys.sorted() {
                guard let child = properties[key] as? [String: Any] else { throw LabError("invalid property schema: \(key)") }
                try audit(child, root: root, depth: depth + 1)
            }
        }
        if type == "array" {
            guard let item = schema["items"] as? [String: Any] else { throw LabError("catalog array schema needs items") }
            try audit(item, root: root, depth: depth + 1)
        }
        if let pattern = schema["pattern"] as? String { _ = try NSRegularExpression(pattern: pattern) }
    }
    private static func check(_ value: Any, schema: [String: Any], root: [String: Any], path: String, depth: Int) throws {
        try require(depth < 64, "\(path): catalog nesting limit exceeded")
        if let ref = schema["$ref"] as? String {
            try check(value, schema: reference(ref, root: root), root: root, path: path, depth: depth + 1)
            return
        }
        func invalid(_ reason: String) -> LabError { LabError("\(path): \(reason)") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw invalid("expected object") }
            let properties = schema["properties"] as! [String: Any]
            let required = schema["required"] as! [String]
            try require(Set(required).isSubset(of: Set(object.keys)), "\(path): missing fields \(Set(required).subtracting(object.keys).sorted())")
            try require(Set(object.keys).isSubset(of: Set(properties.keys)), "\(path): unknown fields \(Set(object.keys).subtracting(properties.keys).sorted())")
            for key in object.keys.sorted() { try check(object[key]!, schema: properties[key] as! [String: Any], root: root, path: path + "." + key, depth: depth + 1) }
        case "array":
            guard let array = value as? [Any] else { throw invalid("expected array") }
            try require(array.count >= (schema["minItems"] as? Int ?? 0), "\(path): too few items")
            if schema["uniqueItems"] as? Bool == true {
                let encoded = try array.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                try require(Set(encoded).count == encoded.count, "\(path): duplicate array values")
            }
            for (index, item) in array.enumerated() { try check(item, schema: schema["items"] as! [String: Any], root: root, path: "\(path)[\(index)]", depth: depth + 1) }
        case "string":
            guard let string = value as? String else { throw invalid("expected string") }
            try require(string.unicodeScalars.count >= (schema["minLength"] as? Int ?? 0), "\(path): empty/short string")
            if let pattern = schema["pattern"] as? String { try require(string.range(of: pattern, options: .regularExpression) != nil, "\(path): invalid string format") }
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { throw invalid("expected integer") }
            if let minimum = schema["minimum"] as? NSNumber { try require(number.doubleValue >= minimum.doubleValue, "\(path): integer below minimum") }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("expected boolean") }
        default: throw invalid("unsupported schema type")
        }
        if let choices = schema["enum"] as? [Any] {
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            let allowed = try choices.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            try require(allowed.contains(encoded), "\(path): invalid enum value")
        }
    }
}
