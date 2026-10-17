import Foundation

/// Exact post-DDL index definitions that can replace one planned definition.
/// information_schema does not expose whether the old FK index was automatic.
struct ForeignKeyIndexReplacement: Codable, Equatable {
    let planned: ApplyIndex
    let alternative: ApplyIndex
}

extension ForeignKeyGraph {
    static func indexReplacements(after: ApplyTable, actions: [AlterAction]) -> [ForeignKeyIndexReplacement] {
        let added = actions.compactMap { action -> (ApplyForeignKey, String?)? in
            if case .addForeignKey(let key, let name) = action { return (key, name) }
            return nil
        }
        func explicit(_ index: ApplyIndex) -> Bool {
            actions.contains { action in
                switch action {
                case .indexes(.rename(_, let new)): return SQLIdentifier.equal(index.name, new)
                case .indexes(.add(let definition)), .indexes(.replace(_, let definition)):
                    return definition.name.isEmpty
                        ? definition.parts == index.parts : SQLIdentifier.equal(definition.name, index.name)
                default: return false
                }
            }
        }
        var result: [ForeignKeyIndexReplacement] = []
        for (key, indexName) in added {
            let name = indexName ?? (key.name.isEmpty ? key.columns[0] : key.name)
            guard !after.secondaryIndexes.contains(where: { SQLIdentifier.equal($0.name, name) }) else { continue }
            let parts = key.columns.map { ApplyIndexPart(column: $0, prefix: nil) }
            for old in after.secondaryIndexes
            where !old.unique && old.type == "BTREE" && old.parts == parts && !explicit(old) {
                let item = ForeignKeyIndexReplacement(
                    planned: old, alternative: ApplyIndex(name: name, unique: false, parts: parts))
                if !result.contains(item) { result.append(item) }
            }
        }
        return result
    }

    /// Match exact index choices without enumerating full-schema combinations.
    /// Each actual replacement can satisfy only one planned index. Required
    /// missing definitions are matched first; recorded removals are optional.
    static func restoringIndexReplacements(
        _ actual: ApplyTable, expected: ApplyTable, removable: [ApplyIndex], replacements: [ForeignKeyIndexReplacement]
    ) -> ApplyTable? {
        let extra = actual.secondaryIndexes.filter { !expected.secondaryIndexes.contains($0) }
        if extra.isEmpty { return actual }
        let absent = expected.secondaryIndexes.filter { !actual.secondaryIndexes.contains($0) }
        let edges = absent.map { old in
            extra.indices.filter { i in replacements.contains(.init(planned: old, alternative: extra[i])) }
        }
        var owner = [Int?](repeating: nil, count: extra.count)
        func assign(_ old: Int, _ seen: inout Set<Int>) -> Bool {
            for candidate in edges[old] where seen.insert(candidate).inserted {
                if let previous = owner[candidate] {
                    if !assign(previous, &seen) { continue }
                }
                owner[candidate] = old
                return true
            }
            return false
        }
        for old in absent.indices where !removable.contains(absent[old]) {
            var seen = Set<Int>()
            if !assign(old, &seen) { return nil }
        }
        for old in absent.indices where removable.contains(absent[old]) {
            var seen = Set<Int>()
            _ = assign(old, &seen)
        }
        guard owner.allSatisfy({ $0 != nil }) else { return nil }
        var restored = actual
        restored.secondaryIndexes =
            (actual.secondaryIndexes.filter { !extra.contains($0) } + owner.compactMap { $0.map { absent[$0] } }).sorted
        { SQLIdentifier.key($0.name) < SQLIdentifier.key($1.name) }
        return restored
    }
}
