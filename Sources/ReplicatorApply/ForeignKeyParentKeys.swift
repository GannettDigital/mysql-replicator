import Foundation

extension ApplyTable {
    func hasForeignKeyParentIndex(_ names:[String],rule:NativeReplicationRules.ForeignKeyParentKeys) -> Bool {
        if rule == .completeUnique {
            return SQLIdentifier.equal(primaryKeyColumns,names) || secondaryIndexes.contains {
                $0.unique && $0.type == "BTREE" && SQLIdentifier.equal($0.parts.compactMap(\.column),names)
                    && $0.parts.allSatisfy { $0.column != nil && $0.prefix == nil && $0.expression == nil }
            }
        }
        if hasForeignKeyIndex(names) { return true }
        // InnoDB appends the clustered key to secondary indexes. Without an
        // explicit PRIMARY KEY, SQL metadata does not identify which eligible
        // unique key was promoted. Admit possible keys; the target checks the
        // actual clustered index before accepting DDL. Do not use our selected
        // DML row identity as evidence of the physical clustered index.
        let clustered = primaryKeyColumns.isEmpty ? eligibleUniqueIdentities.map(\.columns) : [primaryKeyColumns]
        return secondaryIndexes.contains { index in
            guard index.type == "BTREE",index.parts.allSatisfy({$0.column != nil && $0.prefix == nil && $0.expression == nil}) else { return false }
            let visible = index.parts.compactMap(\.column)
            return clustered.contains { key in
                let extended = visible + key.filter { !SQLIdentifier.contains(visible,$0) }
                return SQLIdentifier.equal(Array(extended.prefix(names.count)),names)
            }
        }
    }
}
