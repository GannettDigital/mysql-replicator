import Foundation

/// Normalize only version-dependent metadata fields. SQL literals and ENUM/SET
/// labels are case-sensitive evidence and must never be rewritten globally.
enum ReverseSchemaComparison {
    static func partitions(_ text: String) throws -> String {
        if text.isEmpty { return text }
        return try text.components(separatedBy: "\n").map { line in
            var fields = line.components(separatedBy: "\t")
            try require(fields.count == 5, "unexpected fixture partition metadata")
            // Shared fixtures use simple column lists. Only strip identifier
            // quoting in that grammar; never touch quoted bounds/SQL literals.
            if fields[3].range(
                of: #"^`?[A-Za-z_][A-Za-z0-9_]*`?(?:, *`?[A-Za-z_][A-Za-z0-9_]*`?)*$"#, options: .regularExpression)
                != nil
            {
                fields[3] = fields[3].replacingOccurrences(of: "`", with: "").replacingOccurrences(of: " ", with: "")
            }
            // Normalize only the two native function spellings used by the
            // partition-expression case. Keep this independent of the applier
            // expression renderer. Bounds, literals and grouping stay intact.
            let identifier = "`?([A-Za-z_][A-Za-z0-9_]*)`?"
            for (pattern, replacement) in [
                ("(?i)^TO_DAYS\\(" + identifier + "\\)$", "to_days($1)"),
                ("(?i)^EXTRACT\\(YEAR_MONTH FROM " + identifier + "\\)$", "extract(year_month from $1)"),
            ] {
                fields[3] = fields[3].replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
            }
            return fields.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func columns(_ text: String, mysql84: Bool) throws -> String {
        if text.isEmpty { return text }
        return try text.components(separatedBy: "\n").map { line in
            var fields = line.components(separatedBy: "\t")
            try require(fields.count == 10, "unexpected fixture column metadata")
            // MySQL 5.7 and 8.4 expose different names for the same encoding.
            // Normalize only metadata fields, never defaults or row values.
            if fields[5] == "utf8" { fields[5] = "utf8mb3" }
            if fields[6].hasPrefix("utf8_") { fields[6] = "utf8mb3_" + fields[6].dropFirst(5) }
            let type = fields[3]
            if !type.hasSuffix(" zerofill") {
                fields[3] = type.replacingOccurrences(
                    of: #"^(tinyint|smallint|mediumint|int|bigint|year)\([0-9]+\)"#, with: "$1",
                    options: .regularExpression)
            }
            if type.hasPrefix("timestamp") || type.hasPrefix("datetime") {
                if fields[7].range(of: #"(?i)^current_timestamp(?:\([0-6]?\))?$"#, options: .regularExpression) != nil {
                    fields[7] = fields[7].uppercased().replacingOccurrences(of: "()", with: "")
                    if fields[8] == "DEFAULT_GENERATED" || fields[8].hasPrefix("DEFAULT_GENERATED on update ") {
                        fields[8] = String(fields[8].dropFirst(17)).trimmingCharacters(in: .whitespaces)
                    }
                }
                if fields[8].range(
                    of: #"(?i)^on update current_timestamp(?:\([0-6]?\))?$"#, options: .regularExpression) != nil
                {
                    fields[8] =
                        "on update " + fields[8].dropFirst(10).uppercased().replacingOccurrences(of: "()", with: "")
                }
            }
            if mysql84 && fields[9].contains("json_extract(") {
                // Only the ASCII JSON paths in the shared fixtures. Preserve
                // other literals and compare their bytes without substitution.
                fields[9] = fields[9].replacingOccurrences(
                    of: #"_utf8mb4\\'([$.A-Za-z0-9_]+)\\'"#, with: "'$1'", options: .regularExpression)
            }
            // Exact spellings observed for the generated-expression fixture.
            // Keep this independent of the production expression parser.
            if mysql84 {
                let known = [
                    "(`n` is null)": "isnull(`n`)",
                    "trim(both _utf8mb4\\'x\\' from `v`)": "trim(both 'x' from `v`)",
                    "_utf8mb4\\'`a`\\'": "'`a`'",
                ]
                fields[9] = known[fields[9]] ?? fields[9]
            }
            return fields.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
