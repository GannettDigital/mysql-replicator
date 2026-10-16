import Foundation
import ReplicatorCodec

enum IndexChange: Equatable {
    case add(ApplyIndex), drop(String), rename(String,String), replace(String,ApplyIndex)
    func applying(to table: ApplyTable) throws -> ApplyTable {
        var indexes=table.secondaryIndexes
        func remove(_ name:String) throws -> ApplyIndex {
            guard !SQLIdentifier.equal(name,"PRIMARY"),let i=indexes.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else {throw ApplyError("secondary index is absent or PRIMARY is unsupported")}
            return indexes.remove(at:i)
        }
        switch self {
        case .add(let definition): let index=definition.resolvingName(among:indexes);indexes.append(index)
        case .drop(let name): _ = try remove(name)
        case .rename(let old,let new):
            let index=try remove(old)
            indexes.append(ApplyIndex(name:new,unique:index.unique,parts:index.parts,type:index.type,parser:index.parser))
        case .replace(let old,let definition): _ = try remove(old);let index=definition.resolvingName(among:indexes);indexes.append(index)
        }
        let result=table.replacing(indexes:indexes);try result.validate(requireRowIdentity:false);return result
    }
}
extension ApplyTable {
    func modifying(_ column:ApplyColumn,placement:ColumnPlacement?) throws -> ApplyTable {
        guard let old=columns.firstIndex(where:{SQLIdentifier.equal($0.name,column.name)}) else {throw ApplyError("MODIFY column is absent")}
        var replacement=column
        if SQLIdentifier.contains(primaryKeyColumns,column.name) {
            replacement.nullable=false
        }
        var next=columns;next.remove(at:old)
        let position:Int
        switch placement {
        case nil: position=old
        case .first: position=0
        case .last: position=next.count
        case .after(let name):
            guard let index=next.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else {throw ApplyError("MODIFY AFTER column absent or self-referential")}
            position=index+1
        }
        next.insert(replacement,at:position)
        let result=replacing(columns:next);try result.validate(requireRowIdentity:false);return result
    }
}

extension TargetSession {
    func altering(_ table: ApplyTable,actions: [AlterAction],context: QuerySessionContext) throws -> ApplyTable {
        var result = table
        // MySQL resolves table options for the whole ALTER, even when ADD or
        // MODIFY appears before the encoding clause in the statement.
        let (encoding,conversion)=try alterEncoding(table,actions:actions,context:context)
        result.defaultCharacterSet=encoding.characterSet;result.defaultCollation=encoding.collation
        if let conversion {
            var columns=result.columns
            for i in columns.indices {
                let name=columns[i].name
                let replaced=actions.contains { action in
                    switch action {
                    case .modify(let old,_,_),.drop(let old): return SQLIdentifier.equal(old,name)
                    default: return false
                    }
                }
                if !replaced { columns[i]=try convertedColumn(columns[i],table:TableName(database:table.database,table:table.table),encoding:conversion,context:context) }
            }
            result=result.replacing(columns:columns)
        }
        func resolve(_ definition:ApplyColumn) throws -> ApplyColumn {
            var column=definition
            if let conversion,try DMLColumnType(column).isText,column.characterSet != "binary",column.collation != "binary" {
                column.characterSet=conversion.characterSet;column.collation=conversion.collation
            }
            return try resolveColumn(column,parent:encoding,context:context,database:table.database)
        }
        // MySQL resolves added FKs against the complete column/index layout,
        // including a DROP INDEX or ADD COLUMN written after the FK clause.
        let ordinary=actions.filter { if case .addForeignKey = $0 {return false};return true }
        let foreignKeys=actions.filter { if case .addForeignKey = $0 {return true};return false }
        for action in ordinary+foreignKeys {
            switch action {
            case .encoding, .ignoredCheck: break
            case .maintenance: break // Native rebuild/index state does not change the stored column schema.
            case .tableOption: break // Original SQL applies the engine-specific option.
            case .addForeignKey(let key,let index): result = try result.addingForeignKey(key,indexName:index)
            case .dropForeignKey(let name):
                guard let i = result.foreignKeys.firstIndex(where: { $0.child == result.identity && SQLIdentifier.equal($0.name,name) }) else { throw ApplyError("DROP foreign key is absent") }
                result.foreignKeys.remove(at:i)
            case .add(let definition,let placement):
                let column = try resolve(definition)
                try require(!result.columns.contains{SQLIdentifier.equal($0.name,column.name)},"DDL ADD column already exists")
                var columns = result.columns
                switch placement {
                case .last: columns.append(column)
                case .first: columns.insert(column,at:0)
                case .after(let name):
                    guard let i = columns.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else { throw ApplyError("DDL AFTER column absent") }
                    columns.insert(column,at:i+1)
                }
                result = result.replacing(columns:columns)
            case .modify(let old,let definition,let placement):
                var column = try resolve(definition)
                guard let i = result.columns.firstIndex(where:{SQLIdentifier.equal($0.name,old)}) else { throw ApplyError("MODIFY/CHANGE column is absent") }
                if !SQLIdentifier.equal(old,column.name) {
                    try require(!result.columns.contains{SQLIdentifier.equal($0.name,column.name)},"CHANGE destination column exists")
                    try require(try !result.secondaryIndexes.flatMap(\.parts).contains { try $0.expression.map { try DDLExpression.references(old,in:$0) } == true },"target cannot rename a column used by a functional index; drop that index first")
                    // MySQL rejects renaming a referenced generated/partition
                    // dependency. Do not invent a different expression rewrite.
                    try require(result.columns.allSatisfy{!($0.generationExpression?.contains((try? quoted(old)) ?? old) ?? false)} && result.partitions.allSatisfy{!$0.expression.contains((try? quoted(old)) ?? old) && ($0.subpartitions ?? []).allSatisfy { !$0.expression.contains((try? quoted(old)) ?? old) }},"CHANGE of a generated/partition dependency is unsupported")
                }
                if SQLIdentifier.contains(result.primaryKeyColumns,old) { column.nullable = false }
                var columns = result.columns; columns.remove(at:i)
                let position: Int
                switch placement {
                case nil: position = i
                case .last: position = columns.count
                case .first: position = 0
                case .after(let name):
                    guard let after = columns.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else { throw ApplyError("CHANGE AFTER column absent or self-referential") }; position = after+1
                }
                columns.insert(column,at:position)
                let indexes = result.secondaryIndexes.map { key in ApplyIndex(name:key.name,unique:key.unique,parts:key.parts.map { ApplyIndexPart(column:SQLIdentifier.equal($0.column ?? "",old) ? column.name : $0.column,prefix:$0.prefix,direction:$0.direction,expression:$0.expression) },type:key.type,parser:key.parser) }
                result = result.replacing(columns:columns,indexes:indexes,primaryKey:result.primaryKeyColumns.map{SQLIdentifier.equal($0,old) ? column.name : $0})
                result.foreignKeys = result.foreignKeys.map { $0.renamingColumn(in:table.identity,from:old,to:column.name) }
            case .drop(let name):
                try require(try !result.secondaryIndexes.flatMap(\.parts).contains { try $0.expression.map { try DDLExpression.references(name,in:$0) } == true },"target cannot drop a column used by a functional index; drop that index first")
                try require(result.columns.contains{SQLIdentifier.equal($0.name,name)},"DROP column is absent")
                let indexes = result.secondaryIndexes.compactMap { key -> ApplyIndex? in
                    let parts = key.parts.filter{!SQLIdentifier.equal($0.column ?? "",name)}
                    return parts.isEmpty ? nil : ApplyIndex(name:key.name,unique:key.unique,parts:parts,type:key.type,parser:key.parser)
                }
                result = result.replacing(columns:result.columns.filter{!SQLIdentifier.equal($0.name,name)},indexes:indexes,primaryKey:result.primaryKeyColumns.filter{!SQLIdentifier.equal($0,name)})
            case .defaultExpression(let name,let expression):
                guard let i=result.columns.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else { throw ApplyError("ALTER DEFAULT column is absent") }
                var columns=result.columns
                try require(!columns[i].isGenerated,"generated column cannot have a default")
                columns[i].defaultValue=nil;columns[i].binaryDefaultBytes=nil;columns[i].choiceDefaultBytes=nil;columns[i].choiceDefaultOrdinal=nil
                columns[i].defaultExpression=expression
                result=result.replacing(columns:columns)
            case .defaultValue(let name,let value,let numeric,let bytes,let literalBytes):
                guard let i = result.columns.firstIndex(where:{SQLIdentifier.equal($0.name,name)}) else { throw ApplyError("ALTER DEFAULT column is absent") }
                var columns = result.columns
                columns[i].defaultExpression=nil
                try require(!columns[i].isGenerated,"generated column cannot have a default")
                let type=try DMLColumnType(columns[i].type)
                let binary=["binary","varbinary"].contains(type.base),text=["char","varchar"].contains(type.base)
                try require(bytes == nil || type.isChoice || binary || text,"binary defaults require separate support for this type")
                columns[i].choiceDefaultBytes=type.isChoice ? (bytes ?? (columns[i].characterSet == "binary" ? literalBytes : nil)) : nil
                columns[i].binaryDefaultBytes=binary ? (bytes ?? literalBytes) : (text ? bytes : nil)
                if binary {
                    columns[i].numericDefaultLiteral = value != nil && numeric ? true : nil
                    columns[i].defaultValue=value
                    columns[i] = try resolveBinaryDefault(columns[i],database:table.database,sqlMode:context.sqlMode)
                } else if text {
                    columns[i].numericDefaultLiteral = value != nil && numeric ? true : nil
                    columns[i].defaultValue=value
                    columns[i] = try resolveTextDefault(columns[i],database:table.database,sqlMode:context.sqlMode)
                } else if type.base == "decimal",value != nil {
                    columns[i].defaultValue=value
                    columns[i].numericDefaultLiteral=numeric
                    columns[i] = try resolveDecimalDefault(columns[i],database:table.database,sqlMode:context.sqlMode)
                } else { columns[i].defaultValue = columns[i].choiceDefaultBytes != nil ? nil : try normalizedDefault(value,type:type) }
                if try DMLColumnType(columns[i]).isChoice {
                    columns[i].numericDefaultLiteral = numeric ? true : nil
                    columns[i] = try resolveChoiceColumn(columns[i],database:table.database,sqlMode:context.sqlMode)
                }
                result = result.replacing(columns:columns)
            case .indexes(let change): result = try change.applying(to:result)
            case .primaryKey(let names):
                if let names {
                    try require(result.primaryKeyColumns.isEmpty,"ADD PRIMARY KEY requires dropping the existing key")
                    var columns = result.columns
                    for i in columns.indices where SQLIdentifier.contains(names,columns[i].name) { columns[i].nullable = false }
                    result = result.replacing(columns:columns,primaryKey:names)
                } else { result = result.replacing(primaryKey:[]) }
            case .partition(let change): result = try change.applying(to:result)
            }
        }
        try result.validate(); return result
    }
}
