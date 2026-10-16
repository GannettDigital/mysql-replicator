import Foundation

/// Names refer to original columns. Apply the map once, never as a rename chain.
struct ColumnNameChanges {
    private let names:[SQLNameKey:String]
    init(_ actions:[AlterAction]) throws {
        var names:[SQLNameKey:String]=[:]
        for action in actions {
            if case .modify(let old,let column,_) = action {
                try require(names.updateValue(column.name,forKey:SQLIdentifier.key(old)) == nil,"column is changed more than once: "+old)
            }
        }
        self.names=names
    }
    func name(_ original:String) -> String { names[SQLIdentifier.key(original)] ?? original }
}

/// Native mysql_prepare_alter_table first replaces original fields, then places
/// ADD and FIRST/AFTER fields in statement order. Keys retain field identities.
enum AlterColumnLayout {
    private struct Entry { let identity:Int; var column:ApplyColumn }
    static func applying(to table:ApplyTable,actions:[AlterAction],resolve:(ApplyColumn)throws->ApplyColumn = {$0}) throws -> ApplyTable {
        try PartitionColumnDependencies.validate(table,actions:actions)
        let names=try ColumnNameChanges(actions)
        var modifications:[SQLNameKey:ApplyColumn]=[:],dropped=Set<SQLNameKey>()
        let original=Dictionary(uniqueKeysWithValues:table.columns.enumerated().map{(SQLIdentifier.key($0.element.name),$0.offset)})
        let dropsPrimary=actions.contains { if case .primaryKey(nil)=$0 {return true};return false }
        for action in actions {
            switch action {
            case .modify(let old,let definition,_):
                try require(original[SQLIdentifier.key(old)] != nil,"MODIFY/CHANGE column is absent: "+old)
                var column=try resolve(definition)
                if !dropsPrimary && SQLIdentifier.contains(table.primaryKeyColumns,old) {column.nullable=false}
                modifications[SQLIdentifier.key(old)]=column
            case .drop(let old):
                let key=SQLIdentifier.key(old)
                try require(original[key] != nil && dropped.insert(key).inserted,"DROP column is absent or repeated: "+old)
            default:break
            }
        }
        try require(dropped.isDisjoint(with:modifications.keys),"cannot DROP and CHANGE the same original column")
        for action in actions {
            let name:String
            switch action {
            case .defaultValue(let old,_,_,_,_),.defaultExpression(let old,_):name=old
            default:continue
            }
            let key=SQLIdentifier.key(name)
            try require(original[key] != nil && modifications[key] == nil && !dropped.contains(key),"ALTER DEFAULT requires an unchanged original column: "+name)
        }
        var entries=table.columns.enumerated().compactMap { i,column -> Entry? in
            let key=SQLIdentifier.key(column.name)
            return dropped.contains(key) ? nil : Entry(identity:i,column:modifications[key] ?? column)
        }
        // Match native field pointers with stable ordinals, not final names.
        for (ordinal,action) in actions.enumerated() {
            let entry:Entry,placement:ColumnPlacement
            switch action {
            case .add(let column,let position):entry=Entry(identity:table.columns.count+ordinal,column:try resolve(column));placement=position
            case .modify(let old,_,.some(let position)):
                let identity=original[SQLIdentifier.key(old)]!
                guard let index=entries.firstIndex(where:{$0.identity == identity}) else {throw ApplyError("missing changed column identity")}
                entry=entries.remove(at:index);placement=position
            default:continue
            }
            switch placement {
            case .last:entries.append(entry)
            case .first:entries.insert(entry,at:0)
            case .after(let name):
                guard let index=entries.firstIndex(where:{SQLIdentifier.equal($0.column.name,name)}) else {throw ApplyError("AFTER column absent or self-referential: "+name)}
                entries.insert(entry,at:index+1)
            }
        }
        let columns=entries.map(\.column)
        try require(Set(columns.map{SQLIdentifier.key($0.name)}).count == columns.count,"duplicate final column name in ALTER")
        func retained(_ name:String) -> Bool {!dropped.contains(SQLIdentifier.key(name))}
        func parts(_ parts:[ApplyIndexPart]) -> [ApplyIndexPart] {
            parts.compactMap { part in
                guard let column=part.column else {return part}
                guard retained(column) else {return nil}
                return .init(column:names.name(column),prefix:part.prefix,direction:part.direction,expression:part.expression)
            }
        }
        let explicitlyRemoved=Set(actions.compactMap { action -> SQLNameKey? in
            switch action {
            case .indexes(.drop(let name)),.indexes(.replace(let name,_)):return SQLIdentifier.key(name)
            default:return nil
            }
        })
        let indexes=table.secondaryIndexes.compactMap { index -> ApplyIndex? in
            let mapped=parts(index.parts)
            // Keep the index identity until its explicit DROP/REPLACE is processed.
            return mapped.isEmpty && !explicitlyRemoved.contains(SQLIdentifier.key(index.name)) ? nil : .init(name:index.name,unique:index.unique,parts:mapped,type:index.type,parser:index.parser,visible:index.visible)
        }
        var result=table.replacing(columns:columns,indexes:indexes,primaryKey:table.primaryKeyColumns.filter(retained).map(names.name),primaryKeyParts:table.primaryKeyParts.map(parts))
        result.foreignKeys=table.foreignKeys.map{$0.renamingColumns(in:table.identity,using:names)}
        return result
    }
}
