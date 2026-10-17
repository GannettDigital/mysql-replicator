import Foundation
import ReplicatorCodec

struct TableRename: Equatable {
    let from: TableName
    let to: TableName

    /// MySQL applies pairs left-to-right. Resolve names against the evolving
    /// namespace, then journal its initial/final schemas (including swaps).
    static func resolve<T>(_ renames:[TableRename],objects:[SQLNameKey:T],rename:(T,TableName) throws -> T) throws -> [SQLNameKey:T] {
        var result=objects
        for pair in renames {
            guard let object=result.removeValue(forKey:pair.from.identity) else { throw ApplyError("DDL RENAME source is absent: \(pair.from.database).\(pair.from.table)") }
            try require(result[pair.to.identity] == nil,"DDL RENAME destination exists: \(pair.to.database).\(pair.to.table)")
            result[pair.to.identity]=try rename(object,pair.to)
        }
        return result
    }

}

extension ApplyTable {
    func renamed(to name: TableName) -> ApplyTable {
        ApplyTable(database:name.database,table:name.table,columns:columns,primaryKeyColumns:primaryKeyColumns,primaryKeyParts:primaryKeyParts,
                   defaultCharacterSet:defaultCharacterSet,defaultCollation:defaultCollation,secondaryIndexes:secondaryIndexes,partitions:partitions,foreignKeys:foreignKeys.map { $0.renamed(TableRename(from:TableName(database:database,table:table),to:name)) })
    }
}

extension TargetSession {
    func prepareRenames(_ renames: [TableRename],source: QueryControl,context: QuerySessionContext) throws -> PreparedDDL {
        var initial: [SQLNameKey:RenameObject] = [:], names: [SQLNameKey:TableName] = [:]
        for rename in renames { names[rename.from.identity] = rename.from; names[rename.to.identity] = rename.to }
        for name in names.values {
            if let view=try readView(name) {
                try require(discovered[name.identity] == nil,"cached table changed to a view before RENAME")
                initial[name.identity] = .view(view)
            } else if try tableExists(name) {
                let current = try readSchema(database:name.database,name:name.table)
                if let cached = discovered[name.identity] { try require(current == cached,"target schema drift before RENAME") }
                initial[name.identity] = .table(current)
            } else { try require(discovered[name.identity] == nil,"target schema disappeared before RENAME") }
        }
        let final = try TableRename.resolve(renames,objects:initial) { try $0.renamed(to:$1) }
        let keys=Set(initial.keys).union(final.keys).sorted()
        let changes=keys.compactMap { key -> SchemaTransition? in
            let before=initial[key]?.table,after=final[key]?.table
            return before == nil && after == nil ? nil : SchemaTransition(before:before,after:after)
        }
        let views=keys.compactMap { key -> ViewTransition? in
            let before=initial[key]?.view,after=final[key]?.view
            return before == nil && after == nil ? nil : ViewTransition(before:before,after:after)
        }
        let finalNames = changes.compactMap{$0.after?.identity}
        try require(Set(discovered.keys).subtracting(names.keys).union(finalNames).count <= maximumCachedTables,"discovered schema limit reached")
        let plan=try prepareForeignKeyTransitions(PreparedDDL(statement:.renameMany(renames),before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self),additional:changes,viewTransitions:views),foreignKeyChecks:context.foreignKeyChecks)
        try setDDLSession(context,source:source)
        return plan
    }
    func applyTableTransitions(_ plan: PreparedDDL) throws {
        // One server-side statement. The journal retains every table if SQL fails.
        _ = try query(plan.sql,textProtocol:true,timeoutSeconds:config.ddlDeadline,mutation:true,rawSQL:plan.rawSQL)
        try resetDMLSession()
        for change in plan.additional {
            if let after = change.after {
                try require(try readSchema(database:after.database,name:after.table) == after,"multi-table DDL target after-schema mismatch")
            } else if let before = change.before, !plan.viewTransitions.contains(where:{$0.after?.name.identity == before.identity}) {
                try require(!(try tableExists(TableName(database:before.database,table:before.table))),"multi-table DDL source remains")
            }
        }
        for change in plan.viewTransitions {
            if let after=change.after {
                try require(try readView(after.name) == after,"DDL RENAME target view metadata mismatch")
            } else if let before=change.before {
                try require(try readView(before.name) == nil,"DDL RENAME source view remains")
            }
        }
        for change in plan.additional { if let before = change.before { discovered.removeValue(forKey:before.identity) } }
        for change in plan.additional { if let after = change.after { discovered[after.identity] = after } }
        try invalidateStatements()
    }
}
