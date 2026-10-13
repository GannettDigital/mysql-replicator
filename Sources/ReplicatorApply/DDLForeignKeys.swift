import Foundation

extension DDLParser {
    mutating func foreignKey(table: TableName,constraint: String?) throws -> (ApplyForeignKey,String?) {
        try require(engine == "InnoDB","foreign keys are unsupported by the DDL contract")
        try expect("FOREIGN"); try expect("KEY")
        let indexName = isNext("(") ? nil : try identifier()
        // 5.7 uses an index_name as the constraint name; 8.4 does not. Require
        // an explicit CONSTRAINT symbol for that spelling instead of rewriting.
        try require(indexName == nil || constraint != nil,"FOREIGN KEY index_name requires an explicit CONSTRAINT name across versions")
        let columns = try keyParts()
        try expect("REFERENCES")
        let first = try identifier()
        let parent = take(".") ? TableName(database:first,table:try identifier()) : TableName(database:table.database,table:first)
        let referenced = try keyParts()
        try require((columns+referenced).allSatisfy { $0.prefix == nil },"foreign-key prefixes are unsupported")
        var key = ApplyForeignKey(name:constraint ?? "",database:table.database,table:table.table,columns:columns.map(\.column),referencedDatabase:parent.database,referencedTable:parent.table,referencedColumns:referenced.map(\.column))
        var seen = Set<String>()
        while take("ON") {
            let operation = try identifier().uppercased()
            try require(["DELETE","UPDATE"].contains(operation) && seen.insert(operation).inserted,"invalid foreign-key action")
            let action: String
            if take("CASCADE") { action = "CASCADE" }
            else if take("RESTRICT") { action = "RESTRICT" }
            else if take("SET") { try expect("NULL"); action = "SET NULL" }
            else { try expect("NO"); try expect("ACTION"); action = "NO ACTION" }
            if operation == "DELETE" { key.onDelete = action } else { key.onUpdate = action }
        }
        return (key,indexName)
    }
}

extension ApplyForeignKey {
    func renamed(_ rename: TableRename) -> ApplyForeignKey {
        var result = self
        if child == rename.from.identity {
            let prefix = rename.from.table + "_ibfk_"
            if name.hasPrefix(prefix) { result.name = rename.to.table + "_ibfk_" + name.dropFirst(prefix.count) }
            result.database = rename.to.database; result.table = rename.to.table
        }
        if parent == rename.from.identity { result.referencedDatabase = rename.to.database; result.referencedTable = rename.to.table }
        return result
    }
}

extension TargetSession {
    /// Predict and journal every affected relationship snapshot before issuing
    /// DDL. A new FK, removed FK or rename changes both ends of the relationship.
    func prepareForeignKeyTransitions(_ input: PreparedDDL) throws -> PreparedDDL {
        guard contract.transactional else { return input }
        var plan = input
        let changes = plan.additional + ((plan.before != nil || plan.after != nil) ? [SchemaTransition(before:plan.before,after:plan.after)] : [])
        var initial: [String:ApplyTable] = [:], definitions: [String:ApplyTable] = [:]
        for change in changes {
            if let before = change.before { initial[before.identity] = before }
            if let after = change.after { definitions[after.identity] = after }
        }
        var pending = Array(initial.values) + Array(definitions.values)
        while let table = pending.popLast() {
            for key in table.foreignKeys {
                for name in [TableName(database:key.database,table:key.table),TableName(database:key.referencedDatabase,table:key.referencedTable)] where initial[name.identity] == nil && definitions[name.identity] == nil {
                    try require(initial.count + definitions.count < 128,"foreign-key DDL table limit exceeded")
                    let related = try readSchema(database:name.database,name:name.table)
                    if let known = discovered[name.identity] { try require(known == related,"foreign-key dependency schema drift before DDL") }
                    initial[name.identity] = related; pending.append(related)
                }
            }
        }
        var relationships: [String:ApplyForeignKey] = [:]
        for table in initial.values { for key in table.foreignKeys { relationships[key.identity] = key } }
        let renames: [TableRename]
        switch plan.statement {
        case .rename(let from,let to): renames = [TableRename(from:from,to:to)]
        case .renameMany(let pairs): renames = pairs
        default: renames = []
        }
        if renames.isEmpty {
            for change in changes {
                if let before = change.before { relationships = relationships.filter { $0.value.child != before.identity } }
            }
            for table in definitions.values { for key in table.foreignKeys where key.child == table.identity { relationships[key.identity] = key } }
        } else {
            for rename in renames {
                var next: [String:ApplyForeignKey] = [:]
                for key in relationships.values {
                    let renamed = key.renamed(rename)
                    try require(next.updateValue(renamed,forKey:renamed.identity) == nil,"foreign-key name collision during RENAME")
                }
                relationships = next
            }
        }
        var final = initial
        for change in changes { if let before = change.before { final.removeValue(forKey:before.identity) } }
        for (id,table) in definitions { final[id] = table }
        let keys = ForeignKeyGraph.sorted(Array(relationships.values))
        // Renaming a column used by another table needs a separate qualification
        // of MySQL's implicit constraint rewrite. All other ALTERs validate the
        // resulting relationship against the complete parent/child metadata.
        try ForeignKeyGraph.validate(keys,tables:final,filter:TableFilter(config.replicateWildIgnoreTable ?? []))
        for id in final.keys { final[id]!.foreignKeys = ForeignKeyGraph.component(id,in:keys) }
        if let after = plan.after { plan.after = final[after.identity] }
        let primaryBefore = plan.before?.identity, primaryAfter = plan.after?.identity
        plan.additional = Set(initial.keys).union(final.keys).sorted().filter { $0 != primaryBefore && $0 != primaryAfter }.compactMap { id in
            guard initial[id] != final[id] || changes.contains(where: { $0.before?.identity == id || $0.after?.identity == id }) else { return nil }
            return SchemaTransition(before:initial[id],after:final[id])
        }
        if let before = plan.before, let after = plan.after, case .alter(_,let actions) = plan.statement {
            let alternatives = try ForeignKeyGraph.indexAlternatives(before:before,after:after,actions:actions)
            if !alternatives.isEmpty { plan.afterAlternatives = alternatives }
        }
        return plan
    }
}


extension ForeignKeyGraph {
    /// MySQL retains an explicit supporting index, but may replace an equal
    /// generated index with the new constraint's index. information_schema does
    /// not expose that provenance. Journal this narrow set of possible schemas
    /// before SQL, then persist only the exact schema the server produced.
    static func indexAlternatives(before: ApplyTable,after: ApplyTable,actions: [AlterAction]) throws -> [ApplyTable] {
        let added = actions.compactMap { action -> (ApplyForeignKey,String?)? in
            if case .addForeignKey(let key,let index) = action { return (key,index) }; return nil
        }
        var alternatives: [ApplyTable] = []
        for (key,index) in added {
            let name = index ?? (key.name.isEmpty ? key.columns[0] : key.name)
            guard !after.secondaryIndexes.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            let parts = key.columns.map { ApplyIndexPart(column:$0,prefix:nil) }
            for old in before.secondaryIndexes where !old.unique && old.parts == parts {
                guard let i = after.secondaryIndexes.firstIndex(of:old) else { continue }
                // Compound changes to supporting indexes need their own model;
                // do not let this allowance absorb unrelated metadata changes.
                try require(actions.count == 1,"ADD FOREIGN KEY with possible supporting-index replacement requires a standalone ALTER")
                var indexes = after.secondaryIndexes
                indexes[i] = ApplyIndex(name:name,unique:false,parts:parts)
                let alternate = after.replacing(indexes:indexes)
                try alternate.validate(); alternatives.append(alternate)
            }
        }
        return alternatives
    }
}
