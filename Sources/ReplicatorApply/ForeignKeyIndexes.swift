import Foundation

extension ForeignKeyGraph {
    /// MySQL can remove an old generated child index when a new BTREE covers
    /// its complete column prefix. information_schema omits the generated flag.
    /// Journal removable definitions, not every possible subset of indexes.
    static func removableIndexes(before:ApplyTable,after:ApplyTable,actions:[AlterAction]) -> [ApplyIndex] {
        let protected = actions.compactMap { action -> String? in
            if case .indexes(.rename(let old,_)) = action { return old }; return nil
        }
        let added = after.secondaryIndexes.filter { index in
            !before.secondaryIndexes.contains { SQLIdentifier.equal($0.name,index.name) }
        }
        func covers(_ parts:[ApplyIndexPart],_ columns:[String]) -> Bool {
            let prefix = Array(parts.prefix(columns.count))
            return prefix.count == columns.count && prefix.allSatisfy { $0.prefix == nil && $0.expression == nil && ($0.direction == nil || $0.direction == "A") }
                && SQLIdentifier.equal(prefix.compactMap(\.column),columns)
        }
        return before.secondaryIndexes.filter { old in
            guard !old.unique,old.type == "BTREE",old.parts.allSatisfy({$0.column != nil && $0.prefix == nil && $0.expression == nil}),
                  !SQLIdentifier.contains(protected,old.name),after.secondaryIndexes.contains(old),
                  (before.foreignKeys+after.foreignKeys).contains(where: { $0.child == before.identity && covers(old.parts,$0.columns) }) else { return false }
            let columns = old.parts.compactMap(\.column)
            return added.contains { $0.type == "BTREE" && covers($0.parts,columns) }
                || (before.primaryKeyColumns != after.primaryKeyColumns && SQLIdentifier.equal(Array(after.primaryKeyColumns.prefix(columns.count)),columns))
        }
    }

    static func matchesIndexes(_ observed:ApplyTable,expected:ApplyTable,removable:[ApplyIndex],replacements:[ForeignKeyIndexReplacement] = []) -> Bool {
        guard let actual=restoringIndexReplacements(observed,expected:expected,removable:removable,replacements:replacements) else {return false}
        if actual == expected { return true }
        // No added or changed index is optional. Restore only a recorded old
        // definition that is absent, then compare every schema field exactly.
        let absent = expected.secondaryIndexes.filter { !actual.secondaryIndexes.contains($0) }
        guard !absent.isEmpty,absent.allSatisfy({removable.contains($0)}),
              actual.foreignKeys.filter({$0.child == actual.identity}).allSatisfy({actual.hasForeignKeyIndex($0.columns)}) else { return false }
        var restored = actual
        restored.secondaryIndexes = (actual.secondaryIndexes+absent).sorted { SQLIdentifier.key($0.name) < SQLIdentifier.key($1.name) }
        return restored == expected
    }
}
