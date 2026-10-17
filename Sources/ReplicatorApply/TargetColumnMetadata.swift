import Foundation

/// Normalize version-specific presentation, never arbitrary default expressions.
/// 8.4 adds DEFAULT_GENERATED and lowercases CURRENT_TIMESTAMP in I_S; 5.7
/// reports the same supported temporal defaults without that marker.
enum TargetColumnMetadata {
    static func defaultValue(_ value: String?, type: String, mysql84 _: Bool) throws -> String? {
        if type.hasSuffix(" zerofill") { return try normalizedDefault(value, type: DMLColumnType(type)) }
        if type == "float" || type == "double" || type.hasPrefix("float ") || type.hasPrefix("double ")
            || type.hasPrefix("float(") || type.hasPrefix("double(")
        {
            return try normalizedDefault(value, type: DMLColumnType(type))
        }
        if type == "bit" || type.hasPrefix("bit(") { return try normalizedDefault(value, type: DMLColumnType(type)) }
        if type.hasPrefix("binary(") || type.hasPrefix("varbinary(") {
            try require(value == nil, "binary defaults require stored-value metadata")
        }
        return temporalDefault(value, type: type)
    }

    static func temporalDefault(_ value: String?, type: String) -> String? {
        guard type.hasPrefix("timestamp") || type.hasPrefix("datetime"), let value,
            value.range(of: #"^current_timestamp(?:\([0-6]?\))?$"#, options: .caseInsensitive.union(.regularExpression))
                != nil
        else { return value }
        return value.uppercased().replacingOccurrences(of: "()", with: "").replacingOccurrences(of: "(0)", with: "")
    }
    static func extra(_ value: String?, defaultValue: String?, type: String) -> String? {
        var result = value ?? ""
        if type.hasPrefix("timestamp") || type.hasPrefix("datetime"),
            defaultValue?.range(
                of: #"^current_timestamp(?:\([0-6]?\))?$"#, options: .caseInsensitive.union(.regularExpression)) != nil,
            result == "DEFAULT_GENERATED" || result.hasPrefix("DEFAULT_GENERATED on update ")
        {
            result = String(result.dropFirst("DEFAULT_GENERATED".count)).trimmingCharacters(in: .whitespaces)
        }
        if result.hasPrefix("on update ") {
            result = "on update " + (temporalDefault(String(result.dropFirst(10)), type: type) ?? "")
        }
        return result.isEmpty ? nil : result
    }
}
