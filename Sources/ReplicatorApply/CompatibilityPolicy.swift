import Foundation

/// Explicit comparison-semantics changes; never a character-set conversion.
public struct CompatibilityPolicy: Codable, Equatable {
    public var collations: [String:String] = [:]
    // Adding a column encoding must not silently expand translation policy.
    private static let translationTargets: Set<UInt32> = [45,46,224]
    func validate() throws {
        for (source,target) in collations {
            let allowed = CharacterSetRegistry.columnCollation(named:target).map { Self.translationTargets.contains($0.id) } ?? false
            try require(source == "utf8mb4_0900_ai_ci" && allowed,
                        "compatibility.collations supports utf8mb4_0900_ai_ci mapped to utf8mb4_unicode_ci, utf8mb4_general_ci or utf8mb4_bin only")
        }
    }
    func targetName(_ source: String) -> String { collations[source] ?? source }
    func targetID(_ source: UInt32) -> UInt32 {
        guard source == 255, let name = collations["utf8mb4_0900_ai_ci"], let id = CharacterSetRegistry.columnCollation(named:name)?.id else { return source }
        return id
    }
    func mappedDefault(_ source: UInt32) -> String? {
        source == 255 ? collations["utf8mb4_0900_ai_ci"] : nil
    }
}

struct DDLSQLEdit {
    let range: Range<Int>
    let replacement: String
}

extension DDLParser {
    mutating func collationName() throws -> String {
        try require(index < tokens.count,"missing DDL collation")
        let token = tokens[index]
        let original = try identifier().lowercased(), target = compatibility.targetName(original)
        if original != target, let range = token.range { edits.append(DDLSQLEdit(range:range,replacement:target)) }
        return target
    }
    /// MySQL 5.7 cannot set default_collation_for_utf8mb4. Make its replacement
    /// explicit only at a parsed charset declaration that has no COLLATE clause.
    mutating func charsetDefault(_ charset: String?,collation: String?,at offset: Int?) -> String? {
        guard charset == "utf8mb4", collation == nil, let offset,
              let mapped = compatibility.mappedDefault(defaultUTF8MB4Collation) else { return collation }
        edits.append(DDLSQLEdit(range:offset..<offset,replacement:" COLLATE "+mapped))
        return mapped
    }
    func translatedSQL(_ source: Data) -> String {
        // Lexer ranges are zero-based byte offsets, including for Data slices.
        var bytes = [UInt8](source)
        for edit in edits.sorted(by:{$0.range.lowerBound > $1.range.lowerBound}) {
            bytes.replaceSubrange(edit.range,with:edit.replacement.utf8)
        }
        return String(decoding:bytes,as:UTF8.self)
    }
}
