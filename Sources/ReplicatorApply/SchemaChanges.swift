import Foundation

enum IndexChange: Equatable {
    case add(ApplyIndex), drop(String), rename(String,String), replace(String,ApplyIndex)
    func applying(to table: ApplyTable) throws -> ApplyTable {
        var indexes=table.secondaryIndexes
        func remove(_ name:String) throws -> ApplyIndex {
            guard name.uppercased() != "PRIMARY",let i=indexes.firstIndex(where:{$0.name.lowercased() == name.lowercased()}) else {throw ApplyError("secondary index is absent or PRIMARY is unsupported")}
            return indexes.remove(at:i)
        }
        switch self {
        case .add(let index): indexes.append(index)
        case .drop(let name): _ = try remove(name)
        case .rename(let old,let new):
            let index=try remove(old)
            indexes.append(ApplyIndex(name:new,unique:index.unique,parts:index.parts,type:index.type))
        case .replace(let old,let index): _ = try remove(old);indexes.append(index)
        }
        let result=table.replacing(indexes:indexes);try result.validate();return result
    }
}
extension ApplyTable {
    func modifying(_ column:ApplyColumn,placement:ColumnPlacement?) throws -> ApplyTable {
        guard let old=columns.firstIndex(where:{$0.name == column.name}) else {throw ApplyError("MODIFY column is absent")}
        func family(_ column:ApplyColumn) -> String {
            column.type.hasPrefix("varchar(") ? "text" : column.type.hasPrefix("varbinary(") ? "binary" : "integer"
        }
        try require(family(columns[old]) == family(column),"cross-family MODIFY is unsupported")
        var replacement=column
        if column.name == primaryKey {
            replacement=ApplyColumn(name:column.name,type:column.type,nullable:false,collation:column.collation,characterSet:column.characterSet)
        }
        var next=columns;next.remove(at:old)
        let position:Int
        switch placement {
        case nil: position=old
        case .first: position=0
        case .last: position=next.count
        case .after(let name):
            guard let index=next.firstIndex(where:{$0.name == name}) else {throw ApplyError("MODIFY AFTER column absent or self-referential")}
            position=index+1
        }
        next.insert(replacement,at:position)
        let result=replacing(columns:next);try result.validate();return result
    }
}
