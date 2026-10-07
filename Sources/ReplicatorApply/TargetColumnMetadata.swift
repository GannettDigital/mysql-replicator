import Foundation

/// Normalize version-specific presentation, never arbitrary default expressions.
/// 8.4 adds DEFAULT_GENERATED and lowercases CURRENT_TIMESTAMP in I_S; 5.7
/// reports the same supported temporal defaults without that marker.
enum TargetColumnMetadata {
    static func defaultValue(_ value: String?, type: String, mysql84: Bool) throws -> String? {
        guard mysql84, let value, value.hasPrefix("0x"),
              type.hasPrefix("binary(") || type.hasPrefix("varbinary(") else { return temporalDefault(value,type:type) }
        // 8.4 I_S renders binary defaults as hex literals without BINARY padding.
        let hex=Array(value.dropFirst(2).utf8)
        try require(hex.count % 2 == 0,"invalid binary default metadata")
        var bytes: [UInt8] = []
        for i in stride(from:0,to:hex.count,by:2) {
            guard let byte=UInt8(String(decoding:hex[i...i+1],as:UTF8.self),radix:16) else { throw ApplyError("invalid binary default metadata") }
            bytes.append(byte)
        }
        guard let literal=String(bytes:bytes,encoding:.utf8) else { throw ApplyError("binary default cannot be represented in supported DDL metadata") }
        return try normalizedDefault(literal,type:DMLColumnType(type))
    }

    static func temporalDefault(_ value: String?, type: String) -> String? {
        guard type.hasPrefix("timestamp") || type.hasPrefix("datetime"), let value,
              value.range(of:#"^current_timestamp(?:\([0-6]?\))?$"#,options:.caseInsensitive.union(.regularExpression)) != nil else { return value }
        return value.uppercased().replacingOccurrences(of:"()",with:"").replacingOccurrences(of:"(0)",with:"")
    }
    static func extra(_ value: String?, defaultValue: String?, type: String) -> String? {
        var result = value ?? ""
        if type.hasPrefix("timestamp") || type.hasPrefix("datetime"),
           defaultValue?.range(of:#"^current_timestamp(?:\([0-6]?\))?$"#,options:.caseInsensitive.union(.regularExpression)) != nil,
           result == "DEFAULT_GENERATED" || result.hasPrefix("DEFAULT_GENERATED on update ") {
            result = String(result.dropFirst("DEFAULT_GENERATED".count)).trimmingCharacters(in:.whitespaces)
        }
        if result.hasPrefix("on update ") {
            result = "on update " + (temporalDefault(String(result.dropFirst(10)),type:type) ?? "")
        }
        return result.isEmpty ? nil : result
    }
}
