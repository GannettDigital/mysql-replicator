import Foundation
import ReplicatorCodec

struct TableRename: Equatable {
    let from: TableName
    let to: TableName

    /// MySQL applies pairs left-to-right. Resolve names against the evolving
    /// namespace, then journal its initial/final schemas (including swaps).
    static func transitions(_ renames: [TableRename],schemas: [String:ApplyTable]) throws -> [SchemaTransition] {
        var result = schemas
        for rename in renames {
            guard let table = result.removeValue(forKey:rename.from.identity) else { throw ApplyError("DDL RENAME source is absent: \(rename.from.database).\(rename.from.table)") }
            try require(result[rename.to.identity] == nil,"DDL RENAME destination exists: \(rename.to.database).\(rename.to.table)")
            result[rename.to.identity] = table.renamed(to:rename.to)
        }
        return Set(schemas.keys).union(result.keys).sorted().map { SchemaTransition(before:schemas[$0],after:result[$0]) }
    }
}

extension ApplyTable {
    func renamed(to name: TableName) -> ApplyTable {
        ApplyTable(database:name.database,table:name.table,columns:columns,primaryKeyColumns:primaryKeyColumns,
                   defaultCharacterSet:defaultCharacterSet,defaultCollation:defaultCollation,secondaryIndexes:secondaryIndexes,partitions:partitions,foreignKeys:foreignKeys.map { $0.renamed(TableRename(from:TableName(database:database,table:table),to:name)) })
    }
}

extension TargetSession {
    func prepareRenames(_ renames: [TableRename],source: QueryControl,context: QuerySessionContext) throws -> PreparedDDL {
        var initial: [String:ApplyTable] = [:], names: [String:TableName] = [:]
        for rename in renames { names[rename.from.identity] = rename.from; names[rename.to.identity] = rename.to }
        for name in names.values {
            if try tableExists(name) {
                let current = try readSchema(database:name.database,name:name.table)
                if let cached = discovered[name.identity] { try require(current == cached,"target schema drift before RENAME") }
                initial[name.identity] = current
            } else { try require(discovered[name.identity] == nil,"target schema disappeared before RENAME") }
        }
        let changes = try TableRename.transitions(renames,schemas:initial)
        let finalNames = changes.compactMap{$0.after?.identity}
        try require(Set(discovered.keys).subtracting(names.keys).union(finalNames).count <= maximumCachedTables,"discovered schema limit reached")
        try setDDLSession(context,source:source)
        return try prepareForeignKeyTransitions(PreparedDDL(statement:.renameMany(renames),before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self),additional:changes))
    }
    func applyRenames(_ plan: PreparedDDL) throws {
        // One server-side statement, never split into separately visible renames.
        _ = try query(plan.sql,textProtocol:true,timeoutSeconds:config.ddlDeadline,mutation:true)
        try resetDMLSession()
        for change in plan.additional {
            if let after = change.after {
                try require(try readSchema(database:after.database,name:after.table) == after,"DDL RENAME target after-schema mismatch")
            } else if let before = change.before {
                try require(!(try tableExists(TableName(database:before.database,table:before.table))),"DDL RENAME source remains")
            }
        }
        for change in plan.additional { if let before = change.before { discovered.removeValue(forKey:before.identity) } }
        for change in plan.additional { if let after = change.after { discovered[after.identity] = after } }
        try invalidateStatements()
    }
}
