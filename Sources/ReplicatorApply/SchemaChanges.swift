import Foundation
import ReplicatorCodec

enum IndexChange: Equatable {
    case add(ApplyIndex), drop(String), rename(String,String), replace(String,ApplyIndex)
    func applying(to table: ApplyTable) throws -> ApplyTable {
        var indexes=table.secondaryIndexes
        func validateAddition(_ index: ApplyIndex) throws {
            try require(!table.foreignKeys.contains { key in
                key.child == table.identity && Array(index.parts.prefix(key.columns.count)).map(\.column) == key.columns
            },"adding a replacement foreign-key supporting index is unsupported; its implicit index removal requires qualification")
        }
        func remove(_ name:String) throws -> ApplyIndex {
            guard name.uppercased() != "PRIMARY",let i=indexes.firstIndex(where:{$0.name.lowercased() == name.lowercased()}) else {throw ApplyError("secondary index is absent or PRIMARY is unsupported")}
            return indexes.remove(at:i)
        }
        switch self {
        case .add(let index): try validateAddition(index); indexes.append(index)
        case .drop(let name): _ = try remove(name)
        case .rename(let old,let new):
            let index=try remove(old)
            indexes.append(ApplyIndex(name:new,unique:index.unique,parts:index.parts,type:index.type))
        case .replace(let old,let index): try validateAddition(index); _ = try remove(old);indexes.append(index)
        }
        let result=table.replacing(indexes:indexes);try result.validate();return result
    }
}
extension ApplyTable {
    func modifying(_ column:ApplyColumn,placement:ColumnPlacement?) throws -> ApplyTable {
        guard let old=columns.firstIndex(where:{$0.name == column.name}) else {throw ApplyError("MODIFY column is absent")}
        func family(_ column:ApplyColumn) -> String {
            guard let type=try? DMLColumnType(column.type) else {return "unsupported"}
            if type.integerBits != nil {return "integer"}
            return type.interpretation.rawValue
        }
        try require(family(columns[old]) == family(column),"cross-family MODIFY is unsupported")
        var replacement=column
        if primaryKeyColumns.contains(column.name) {
            replacement.nullable=false
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

extension TargetSession {
    func altering(_ table: ApplyTable,actions: [AlterAction],context: QuerySessionContext) throws -> ApplyTable {
        var result = table
        let encoding = DDLEncoding(characterSet:table.defaultCharacterSet!,collation:table.defaultCollation!)
        for action in actions {
            switch action {
            case .addForeignKey(let key,let index): result = try result.addingForeignKey(key,indexName:index)
            case .dropForeignKey(let name):
                guard let i = result.foreignKeys.firstIndex(where: { $0.child == result.identity && $0.name.lowercased() == name.lowercased() }) else { throw ApplyError("DROP foreign key is absent") }
                result.foreignKeys.remove(at:i)
            case .add(let definition,let placement):
                let column = try resolveColumn(definition,parent:encoding,context:context)
                try require(!result.columns.contains{$0.name == column.name},"DDL ADD column already exists")
                var columns = result.columns
                switch placement {
                case .last: columns.append(column)
                case .first: columns.insert(column,at:0)
                case .after(let name):
                    guard let i = columns.firstIndex(where:{$0.name == name}) else { throw ApplyError("DDL AFTER column absent") }
                    columns.insert(column,at:i+1)
                }
                result = result.replacing(columns:columns)
            case .modify(let old,let definition,let placement):
                var column = try resolveColumn(definition,parent:encoding,context:context)
                guard let i = result.columns.firstIndex(where:{$0.name == old}) else { throw ApplyError("MODIFY/CHANGE column is absent") }
                let oldType = try DMLColumnType(result.columns[i].type), newType = try DMLColumnType(column.type)
                try require((oldType.integerBits != nil && newType.integerBits != nil) || (oldType.integerBits == nil && newType.integerBits == nil && oldType.interpretation == newType.interpretation),"cross-family MODIFY/CHANGE is unsupported")
                if old != column.name {
                    try require(!result.columns.contains{$0.name == column.name},"CHANGE destination column exists")
                    // MySQL rejects renaming a referenced generated/partition
                    // dependency. Do not invent a different expression rewrite.
                    try require(result.columns.allSatisfy{!($0.generationExpression?.contains((try? quoted(old)) ?? old) ?? false)} && result.partitions.allSatisfy{!$0.expression.contains((try? quoted(old)) ?? old)},"CHANGE of a generated/partition dependency is unsupported")
                }
                if result.primaryKeyColumns.contains(old) { column.nullable = false }
                var columns = result.columns; columns.remove(at:i)
                let position: Int
                switch placement {
                case nil: position = i
                case .last: position = columns.count
                case .first: position = 0
                case .after(let name):
                    guard let after = columns.firstIndex(where:{$0.name == name}) else { throw ApplyError("CHANGE AFTER column absent or self-referential") }; position = after+1
                }
                columns.insert(column,at:position)
                let indexes = result.secondaryIndexes.map { key in ApplyIndex(name:key.name,unique:key.unique,parts:key.parts.map { ApplyIndexPart(column:$0.column == old ? column.name : $0.column,prefix:$0.prefix,direction:$0.direction) },type:key.type) }
                result = result.replacing(columns:columns,indexes:indexes,primaryKey:result.primaryKeyColumns.map{$0 == old ? column.name : $0})
            case .drop(let name):
                try require(result.columns.contains{$0.name == name},"DROP column is absent")
                let indexes = result.secondaryIndexes.compactMap { key -> ApplyIndex? in
                    let parts = key.parts.filter{$0.column != name}
                    return parts.isEmpty ? nil : ApplyIndex(name:key.name,unique:key.unique,parts:parts,type:key.type)
                }
                result = result.replacing(columns:result.columns.filter{$0.name != name},indexes:indexes,primaryKey:result.primaryKeyColumns.filter{$0 != name})
            case .defaultValue(let name,let value):
                guard let i = result.columns.firstIndex(where:{$0.name == name}) else { throw ApplyError("ALTER DEFAULT column is absent") }
                var columns = result.columns
                try require(!columns[i].isGenerated,"generated column cannot have a default")
                columns[i].defaultValue = try normalizedDefault(value,type:DMLColumnType(columns[i].type))
                result = result.replacing(columns:columns)
            case .indexes(let change): result = try change.applying(to:result)
            case .primaryKey(let names):
                if let names {
                    try require(result.primaryKeyColumns.isEmpty,"ADD PRIMARY KEY requires dropping the existing key")
                    var columns = result.columns
                    for i in columns.indices where names.contains(columns[i].name) { columns[i].nullable = false }
                    result = result.replacing(columns:columns,primaryKey:names)
                } else { result = result.replacing(primaryKey:[]) }
            case .partition(let change): result = try change.applying(to:result)
            }
        }
        try result.validate(); return result
    }
}
