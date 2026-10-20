import Foundation
import ReplicatorCodec

enum IndexChange: Equatable {
    case add(ApplyIndex)
    case drop(String)
    case rename(String, String)
    case replace(String, ApplyIndex)
    case visibility(String, Bool)
    func applying(to table: ApplyTable, validateResult: Bool = true) throws -> ApplyTable {
        var indexes = table.secondaryIndexes
        func remove(_ name: String) throws -> ApplyIndex {
            guard !SQLIdentifier.equal(name, "PRIMARY"),
                let i = indexes.firstIndex(where: { SQLIdentifier.equal($0.name, name) })
            else { throw ApplyError("secondary index is absent or PRIMARY is unsupported") }
            return indexes.remove(at: i)
        }
        switch self {
        case .add(let definition):
            let index = try definition.resolvingName(among: indexes)
            indexes.append(index)
        case .drop(let name): _ = try remove(name)
        case .rename(let old, let new):
            let index = try remove(old)
            indexes.append(
                ApplyIndex(
                    name: new, unique: index.unique, parts: index.parts, type: index.type, parser: index.parser,
                    visible: index.visible))
        case .visibility(let name, let visible):
            var index = try remove(name)
            index.visible = visible ? nil : false
            indexes.append(index)
        case .replace(let old, let definition):
            _ = try remove(old)
            let index = try definition.resolvingName(among: indexes)
            indexes.append(index)
        }
        let result = table.replacing(indexes: indexes)
        if validateResult { try result.validate(requireRowIdentity: false) }
        return result
    }
}
extension ApplyTable {
    func modifying(_ column: ApplyColumn, placement: ColumnPlacement?) throws -> ApplyTable {
        guard let old = columns.firstIndex(where: { SQLIdentifier.equal($0.name, column.name) }) else {
            throw ApplyError("MODIFY column is absent")
        }
        var replacement = column
        if SQLIdentifier.contains(primaryKeyColumns, column.name) {
            replacement.nullable = false
        }
        var next = columns
        next.remove(at: old)
        let position: Int
        switch placement {
        case nil: position = old
        case .first: position = 0
        case .last: position = next.count
        case .after(let name):
            guard let index = next.firstIndex(where: { SQLIdentifier.equal($0.name, name) }) else {
                throw ApplyError("MODIFY AFTER column absent or self-referential")
            }
            position = index + 1
        }
        next.insert(replacement, at: position)
        let result = replacing(columns: next)
        try result.validate(requireRowIdentity: false)
        return result
    }
}

extension TargetSession {
    func altering(_ table: ApplyTable, actions: [AlterAction], context: QuerySessionContext) throws -> ApplyTable {
        try ColumnExpressionDependencies.validate(
            table, actions: actions, rules: NativeReplicationRules(profile: config.replicationProfile))
        var result = table
        // MySQL resolves table options for the whole ALTER, even when ADD or
        // MODIFY appears before the encoding clause in the statement.
        let (encoding, conversion) = try alterEncoding(table, actions: actions, context: context)
        result.defaultCharacterSet = encoding.characterSet
        result.defaultCollation = encoding.collation
        if let conversion {
            var columns = result.columns
            for i in columns.indices {
                let name = columns[i].name
                let replaced = actions.contains { action in
                    switch action {
                    case .modify(let old, _, _), .drop(let old): return SQLIdentifier.equal(old, name)
                    default: return false
                    }
                }
                if !replaced {
                    columns[i] = try convertedColumn(
                        columns[i], table: TableName(database: table.database, table: table.table),
                        encoding: conversion, context: context)
                }
            }
            result = result.replacing(columns: columns)
        }
        func resolve(_ definition: ApplyColumn) throws -> ApplyColumn {
            var column = definition
            if let conversion, try DMLColumnType(column).isText, column.characterSet != "binary",
                column.collation != "binary"
            {
                column.characterSet = conversion.characterSet
                column.collation = conversion.collation
            }
            return try resolveColumn(column, parent: encoding, context: context, database: table.database)
        }
        result = try AlterColumnLayout.applying(to: result, actions: actions, resolve: resolve)
        // MySQL resolves added keys against the complete column layout. A key
        // clause can precede its column or the DROP of the old primary key.
        func addsKey(_ action: AlterAction) -> Bool {
            switch action {
            case .primaryKey(.some), .primaryKeyParts, .indexes(.add): return true
            default: return false
            }
        }
        let ordinary = actions.filter {
            if case .addForeignKey = $0 { return false }
            return !addsKey($0)
        }
        let keys = actions.filter(addsKey)
        let foreignKeys = actions.filter {
            if case .addForeignKey = $0 { return true }
            return false
        }
        for action in ordinary + keys + foreignKeys {
            switch action {
            case .encoding, .ignoredCheck, .renameTable: break
            case .renameColumn: throw ApplyError("column rename must be expanded before schema prediction")
            case .maintenance: break  // Native rebuild/index state does not change the stored column schema.
            case .tableOption: break  // Original SQL applies the engine-specific option.
            case .addForeignKey(let key, let index): result = try result.addingForeignKey(key, indexName: index)
            case .dropForeignKey(let name):
                guard
                    let i = result.foreignKeys.firstIndex(where: {
                        $0.child == result.identity && SQLIdentifier.equal($0.name, name)
                    })
                else { throw ApplyError("DROP foreign key is absent") }
                result.foreignKeys.remove(at: i)
            case .add, .modify, .drop: break  // Resolved together from original column identities.
            case .defaultExpression(let name, let expression):
                guard let i = result.columns.firstIndex(where: { SQLIdentifier.equal($0.name, name) }) else {
                    throw ApplyError("ALTER DEFAULT column is absent")
                }
                var columns = result.columns
                try require(!columns[i].isGenerated, "generated column cannot have a default")
                columns[i].defaultValue = nil
                columns[i].binaryDefaultBytes = nil
                columns[i].choiceDefaultBytes = nil
                columns[i].choiceDefaultOrdinal = nil
                columns[i].defaultExpression = expression
                result = result.replacing(columns: columns)
            case .defaultValue(let name, let value, let numeric, let bytes, let literalBytes):
                guard let i = result.columns.firstIndex(where: { SQLIdentifier.equal($0.name, name) }) else {
                    throw ApplyError("ALTER DEFAULT column is absent")
                }
                var columns = result.columns
                columns[i].defaultExpression = nil
                try require(!columns[i].isGenerated, "generated column cannot have a default")
                let type = try DMLColumnType(columns[i].type)
                let binary = ["binary", "varbinary"].contains(type.base)
                let text = ["char", "varchar"].contains(type.base)
                try require(
                    bytes == nil || type.isChoice || binary || text,
                    "binary defaults require separate support for this type")
                columns[i].choiceDefaultBytes =
                    type.isChoice ? (bytes ?? (columns[i].characterSet == "binary" ? literalBytes : nil)) : nil
                columns[i].binaryDefaultBytes = binary ? (bytes ?? literalBytes) : (text ? bytes : nil)
                if binary {
                    columns[i].numericDefaultLiteral = value != nil && numeric ? true : nil
                    columns[i].defaultValue = value
                    columns[i] = try resolveBinaryDefault(
                        columns[i], database: table.database, sqlMode: context.sqlMode)
                } else if text {
                    columns[i].numericDefaultLiteral = value != nil && numeric ? true : nil
                    columns[i].defaultValue = value
                    columns[i] = try resolveTextDefault(columns[i], database: table.database, sqlMode: context.sqlMode)
                } else if type.base == "decimal", value != nil {
                    columns[i].defaultValue = value
                    columns[i].numericDefaultLiteral = numeric
                    columns[i] = try resolveDecimalDefault(
                        columns[i], database: table.database, sqlMode: context.sqlMode)
                } else {
                    columns[i].defaultValue =
                        columns[i].choiceDefaultBytes != nil ? nil : try normalizedDefault(value, type: type)
                }
                if try DMLColumnType(columns[i]).isChoice {
                    columns[i].numericDefaultLiteral = numeric ? true : nil
                    columns[i] = try resolveChoiceColumn(columns[i], database: table.database, sqlMode: context.sqlMode)
                }
                result = result.replacing(columns: columns)
            // Intermediate layouts can temporarily lack an AUTO_INCREMENT key.
            // Validate the complete statement below, before target SQL.
            case .indexes(let change): result = try change.applying(to: result, validateResult: false)
            case .primaryKeyParts(let parts):
                try require(result.primaryKeyColumns.isEmpty, "ADD PRIMARY KEY requires dropping the existing key")
                let names = parts.compactMap(\.column)
                var columns = result.columns
                for i in columns.indices where SQLIdentifier.contains(names, columns[i].name) {
                    columns[i].nullable = false
                }
                result = result.replacing(columns: columns, primaryKey: names, primaryKeyParts: parts)
            case .primaryKey(let names):
                if let names {
                    try require(result.primaryKeyColumns.isEmpty, "ADD PRIMARY KEY requires dropping the existing key")
                    var columns = result.columns
                    for i in columns.indices where SQLIdentifier.contains(names, columns[i].name) {
                        columns[i].nullable = false
                    }
                    result = result.replacing(columns: columns, primaryKey: names)
                } else {
                    result = result.replacing(primaryKey: [])
                }
            case .partition(let change): result = try change.applying(to: result)
            }
        }
        try result.validate()
        return result
    }
}
