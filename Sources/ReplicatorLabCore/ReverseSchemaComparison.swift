import Foundation

/// Normalize only version-dependent metadata fields. SQL literals and ENUM/SET
/// labels are case-sensitive evidence and must never be rewritten globally.
enum ReverseSchemaComparison {
    static func partitions(_ text: String) throws -> String {
        if text.isEmpty { return text }
        return try text.components(separatedBy:"\n").map { line in
            var fields=line.components(separatedBy:"\t")
            try require(fields.count == 5,"unexpected fixture partition metadata")
            // Shared fixtures use simple column lists. Only strip identifier
            // quoting in that grammar; never touch quoted bounds/SQL literals.
            if fields[3].range(of:#"^`?[A-Za-z_][A-Za-z0-9_]*`?(?:, *`?[A-Za-z_][A-Za-z0-9_]*`?)*$"#,options:.regularExpression) != nil {
                fields[3]=fields[3].replacingOccurrences(of:"`",with:"").replacingOccurrences(of:" ",with:"")
            }
            return fields.joined(separator:"\t")
        }.joined(separator:"\n")
    }

    static func columns(_ text: String, mysql84: Bool) throws -> String {
        if text.isEmpty { return text }
        return try text.components(separatedBy:"\n").map { line in
            var fields=line.components(separatedBy:"\t")
            try require(fields.count == 10,"unexpected fixture column metadata")
            let type=fields[3]
            fields[3]=type.replacingOccurrences(of:#"^(tinyint|smallint|mediumint|int|bigint|year)\([0-9]+\)"#,with:"$1",options:.regularExpression)
            if mysql84, fields[7].hasPrefix("0x"), type.hasPrefix("binary(") || type.hasPrefix("varbinary(") {
                let hex=Array(fields[7].dropFirst(2))
                try require(hex.count % 2 == 0,"invalid binary fixture default")
                let bytes=try stride(from:0,to:hex.count,by:2).map { index -> UInt8 in
                    guard let value=UInt8(String(hex[index...index+1]),radix:16) else { throw LabError("invalid binary fixture default") }
                    return value
                }
                var value=String(decoding:bytes,as:UTF8.self)
                if type.hasPrefix("binary("), let width=Int(type.dropFirst(7).dropLast()) {
                    try require(bytes.count <= width,"binary fixture default exceeds width")
                    value += String(repeating:"\0",count:width-bytes.count)
                }
                fields[7]=value
            }
            if type.hasPrefix("timestamp") || type.hasPrefix("datetime") {
                if fields[7].range(of:#"(?i)^current_timestamp(?:\([0-6]?\))?$"#,options:.regularExpression) != nil {
                    fields[7]=fields[7].uppercased().replacingOccurrences(of:"()",with:"")
                    if fields[8] == "DEFAULT_GENERATED" || fields[8].hasPrefix("DEFAULT_GENERATED on update ") {
                        fields[8]=String(fields[8].dropFirst(17)).trimmingCharacters(in:.whitespaces)
                    }
                }
                if fields[8].range(of:#"(?i)^on update current_timestamp(?:\([0-6]?\))?$"#,options:.regularExpression) != nil {
                    fields[8]="on update "+fields[8].dropFirst(10).uppercased().replacingOccurrences(of:"()",with:"")
                }
            }
            return fields.joined(separator:"\t")
        }.joined(separator:"\n")
    }
}
