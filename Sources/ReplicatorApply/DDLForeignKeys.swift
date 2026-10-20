import Foundation

extension DDLParser {
    mutating func foreignKey(table: TableName, constraint: String?) throws -> (ApplyForeignKey, String?) {
        try require(engine == "InnoDB", "foreign keys are unsupported by the DDL contract")
        try expect("FOREIGN")
        try expect("KEY")
        let indexName = isNext("(") ? nil : try identifier()
        let columns = try keyParts()
        try expect("REFERENCES")
        let first = try identifier()
        let parent =
            take(".")
            ? TableName(database: storedTableName(first), table: storedTableName(try identifier()))
            : TableName(database: table.database, table: storedTableName(first))
        let referenced = try keyParts()
        try require(
            (columns + referenced).allSatisfy { $0.prefix == nil && $0.column != nil },
            "foreign-key prefixes and expressions are unsupported")
        let matchStart = index
        let hasMatch = take("MATCH")
        if hasMatch {
            try require(take("FULL") || take("PARTIAL") || take("SIMPLE"), "invalid foreign-key MATCH clause")
        }
        let ignoreActions = hasMatch && nativeRules.foreignKeyMatchIgnoresActions
        var key = ApplyForeignKey(
            name: constraint ?? "", database: table.database, table: table.table,
            columns: columns.map { $0.column ?? "" }, referencedDatabase: parent.database,
            referencedTable: parent.table, referencedColumns: referenced.map { $0.column ?? "" },
            onUpdate: nativeRules.foreignKeyDefaultAction, onDelete: nativeRules.foreignKeyDefaultAction)
        var seen = Set<String>()
        while take("ON") {
            let operation = try identifier().uppercased()
            try require(
                ["DELETE", "UPDATE"].contains(operation) && seen.insert(operation).inserted,
                "invalid foreign-key action")
            let action: String
            if take("CASCADE") {
                action = "CASCADE"
            } else if take("RESTRICT") {
                action = "RESTRICT"
            } else if take("SET") {
                if take("NULL") {
                    action = "SET NULL"
                } else {
                    try expect("DEFAULT")
                    try require(ignoreActions, "InnoDB does not support FK SET DEFAULT")
                    action = "SET DEFAULT"
                }
            } else {
                try expect("NO")
                try expect("ACTION")
                action = "NO ACTION"
            }
            if operation == "DELETE" { key.onDelete = action } else { key.onUpdate = action }
        }
        if ignoreActions {
            key.onUpdate = nativeRules.foreignKeyDefaultAction
            key.onDelete = nativeRules.foreignKeyDefaultAction
            // 5.7's InnoDB SQL scanner stops before MATCH. 8.4 would retain the
            // following actions. Remove the parsed clause, preserving all other bytes.
            edits.append(.init(range: try itemRange(from: matchStart), replacement: ""))
            ignoredForeignKeyMatchCount += 1
        }
        // Both tested versions prefer the explicit CONSTRAINT symbol for an
        // automatically created supporting index. An index name alone does not
        // name the constraint; the server generates table_ibfk_N.
        return (key, constraint ?? indexName)
    }
}

extension ApplyForeignKey {
    func renamingColumns(in table: SQLNameKey, using names: ColumnNameChanges) -> ApplyForeignKey {
        var result = self
        if child == table { result.columns = columns.map(names.name) }
        if parent == table { result.referencedColumns = referencedColumns.map(names.name) }
        return result
    }

    func renamed(_ rename: TableRename) -> ApplyForeignKey {
        var result = self
        if child == rename.from.identity {
            let prefix = rename.from.table + "_ibfk_"
            if name.hasPrefix(prefix) { result.name = rename.to.table + "_ibfk_" + name.dropFirst(prefix.count) }
            result.database = rename.to.database
            result.table = rename.to.table
        }
        if parent == rename.from.identity {
            result.referencedDatabase = rename.to.database
            result.referencedTable = rename.to.table
        }
        return result
    }
}

extension TargetSession {
    /// Predict and journal every affected relationship snapshot before issuing
    /// DDL. A new FK, removed FK or rename changes both ends of the relationship.
    func prepareForeignKeyTransitions(_ input: PreparedDDL, foreignKeyChecks: Bool) throws -> PreparedDDL {
        guard contract.transactional else { return input }
        var plan = input
        let changes =
            plan.additional
            + ((plan.before != nil || plan.after != nil)
                ? [SchemaTransition(before: plan.before, after: plan.after)] : [])
        var initial: [SQLNameKey: ApplyTable] = [:]
        var definitions: [SQLNameKey: ApplyTable] = [:]
        for change in changes {
            if let before = change.before { initial[before.identity] = before }
            if var after = change.after {
                // A newly created parent can already have incoming edges from
                // children created while checks were disabled.
                if change.before == nil {
                    var keys = Dictionary(
                        uniqueKeysWithValues: try readForeignKeys(
                            TableName(database: after.database, table: after.table)
                        ).map { ($0.identity, $0) })
                    for key in after.foreignKeys { keys[key.identity] = key }
                    after.foreignKeys = ForeignKeyGraph.sorted(Array(keys.values))
                }
                definitions[after.identity] = after
            }
        }
        var absent = Set<SQLNameKey>()
        var pending = Array(initial.values) + Array(definitions.values)
        while let table = pending.popLast() {
            for key in table.foreignKeys {
                for name in [
                    TableName(database: key.database, table: key.table),
                    TableName(database: key.referencedDatabase, table: key.referencedTable),
                ]
                where initial[name.identity] == nil && definitions[name.identity] == nil
                    && !absent.contains(name.identity)
                {
                    try require(initial.count + definitions.count < 128, "foreign-key DDL table limit exceeded")
                    guard try tableExists(name) else {
                        try require(discovered[name.identity] == nil, "foreign-key dependency disappeared before DDL")
                        absent.insert(name.identity)
                        continue
                    }
                    let related = try readSchema(database: name.database, name: name.table)
                    if let known = discovered[name.identity] {
                        try require(known == related, "foreign-key dependency schema drift before DDL")
                    }
                    initial[name.identity] = related
                    pending.append(related)
                }
            }
        }
        var relationships: [SQLNameKey: ApplyForeignKey] = [:]
        for table in initial.values { for key in table.foreignKeys { relationships[key.identity] = key } }
        // Original relationships are mapped once. Definitions below already
        // contain final child columns and newly added FKs; do not map them again.
        if case .alter(let table, let actions) = plan.statement {
            let names = try ColumnNameChanges(actions)
            relationships = relationships.mapValues { $0.renamingColumns(in: table.identity, using: names) }
        }
        let renames: [TableRename]
        switch plan.statement {
        case .rename(let from, let to): renames = [TableRename(from: from, to: to)]
        case .renameMany(let pairs): renames = pairs
        default: renames = []
        }
        if renames.isEmpty {
            for change in changes {
                if let before = change.before {
                    relationships = relationships.filter { $0.value.child != before.identity }
                }
            }
            for table in definitions.values {
                for key in table.foreignKeys where key.child == table.identity { relationships[key.identity] = key }
            }
        } else {
            for rename in renames {
                var next: [SQLNameKey: ApplyForeignKey] = [:]
                for key in relationships.values {
                    let renamed = key.renamed(rename)
                    try require(
                        next.updateValue(renamed, forKey: renamed.identity) == nil,
                        "foreign-key name collision during RENAME")
                }
                relationships = next
            }
        }
        var final = initial
        for change in changes { if let before = change.before { final.removeValue(forKey: before.identity) } }
        for (id, table) in definitions { final[id] = table }
        let keys = ForeignKeyGraph.sorted(Array(relationships.values))
        let missing =
            foreignKeyChecks
            ? Set(initial.values.flatMap(\.foreignKeys).map(\.parent)).intersection(absent)
            : Set(keys.map(\.parent)).subtracting(final.keys)
        try ForeignKeyGraph.validate(
            keys, tables: final,
            filter: TableFilter(
                config.replicateWildIgnoreTable ?? [], including: config.replicateWildDoTable ?? [],
                lowerCaseTableNames: config.source.tableNameCaseSetting), missingParents: missing,
            parentKeys: NativeReplicationRules(profile: config.replicationProfile).foreignKeyParentKeys)
        for id in final.keys { final[id]!.foreignKeys = ForeignKeyGraph.component(id, in: keys) }
        if let after = plan.after { plan.after = final[after.identity] }
        let primaryBefore = plan.before?.identity
        let primaryAfter = plan.after?.identity
        plan.additional = Set(initial.keys).union(final.keys).sorted().filter {
            $0 != primaryBefore && $0 != primaryAfter
        }.compactMap { id in
            // DROP DATABASE must also record surviving children whose FK
            // still points to the now-absent parent. Their schema can be unchanged.
            guard
                plan.statement.alterRenameDestination != nil || plan.database != nil || initial[id] != final[id]
                    || changes.contains(where: { $0.before?.identity == id || $0.after?.identity == id })
            else { return nil }
            return SchemaTransition(before: initial[id], after: final[id])
        }
        let indexActions: [AlterAction]
        switch plan.statement {
        case .alter(_, let actions): indexActions = actions
        case .indexes(_, let change): indexActions = [.indexes(change)]
        default: indexActions = []
        }
        if let before = plan.before, let after = plan.after, !indexActions.isEmpty {
            let actions = indexActions
            let replacements = ForeignKeyGraph.indexReplacements(after: after, actions: actions)
            if !replacements.isEmpty { plan.supportingIndexReplacements = replacements }
            let removable = try ForeignKeyGraph.removableIndexes(before: before, after: after, actions: actions)
            if !removable.isEmpty { plan.removableSupportingIndexes = removable }
        }
        return plan
    }
}
