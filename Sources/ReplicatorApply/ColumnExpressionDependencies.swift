import Foundation

/// Native checks use the whole ALTER, not the order of its clauses. Expressions
/// are canonical SQL, so identifier tokens distinguish columns from literals.
enum ColumnExpressionDependencies {
    static func validate(_ table: ApplyTable, actions: [AlterAction], rules: NativeReplicationRules) throws {
        func replacedOrDropped(_ name: String) -> Bool {
            actions.contains {
                switch $0 {
                case .modify(let old, _, _), .drop(let old): return SQLIdentifier.equal(old, name)
                default: return false
                }
            }
        }
        for action in actions {
            let name: String
            let dropping: Bool
            switch action {
            case .modify(let old, let new, _) where !SQLIdentifier.equal(old, new.name):
                name = old
                dropping = false
            case .drop(let old):
                name = old
                dropping = true
            default: continue
            }
            for index in table.secondaryIndexes {
                let removed = actions.contains {
                    switch $0 {
                    case .indexes(.drop(let old)), .indexes(.replace(let old, _)):
                        return SQLIdentifier.equal(old, index.name)
                    default: return false
                    }
                }
                if removed { continue }
                for part in index.parts {
                    guard let expression = part.expression,
                        try DDLExpression.references(name, in: expression)
                    else { continue }
                    throw ApplyError(
                        "cannot \(dropping ? "DROP" : "CHANGE") column \(name): functional index \(index.name) depends on it; drop or replace that index in the same ALTER"
                    )
                }
            }
            for column in table.columns {
                if let expression = column.defaultExpression,
                    try DDLExpression.references(name, in: expression)
                {
                    let changedDefault = actions.contains {
                        switch $0 {
                        case .defaultExpression(let old, _), .defaultValue(let old, _, _, _, _):
                            return SQLIdentifier.equal(old, column.name)
                        default: return false
                        }
                    }
                    try require(
                        replacedOrDropped(column.name) || changedDefault,
                        "cannot \(dropping ? "DROP" : "CHANGE") column \(name): unchanged default expression of column \(column.name) depends on it; replace or remove its default in the same ALTER"
                    )
                }
                guard let expression = column.generationExpression,
                    try DDLExpression.references(name, in: expression)
                else { continue }
                if dropping && rules.dropChecksOriginalGeneratedDependencies {
                    throw ApplyError(
                        "target MySQL 5.7 cannot DROP column \(name): generated column \(column.name) depends on it (native error 3108); remove the dependency in a separate ALTER first"
                    )
                }
                try require(
                    replacedOrDropped(column.name),
                    "cannot \(dropping ? "DROP" : "CHANGE") column \(name): unchanged generated column \(column.name) depends on it; replace or remove its expression in the same ALTER"
                )
            }
        }
    }
}
