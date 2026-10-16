import Foundation

extension ApplyTable {
    var effectivePrimaryKeyParts:[ApplyIndexPart] {
        primaryKeyParts ?? primaryKeyColumns.map { .init(column:$0,prefix:nil) }
    }
    func validatePrimaryKeyParts() throws {
        let parts=effectivePrimaryKeyParts
        try require(SQLIdentifier.equal(parts.compactMap(\.column),primaryKeyColumns) && parts.count == primaryKeyColumns.count,"primary-key parts differ from key columns")
        for part in parts {
            guard let name=part.column,let column=columns.first(where:{SQLIdentifier.equal($0.name,name)}) else {throw ApplyError("missing primary key column")}
            let type=try DMLColumnType(column)
            try require(!column.nullable && !column.isGenerated && !type.isSpatial && type.base != "json" && part.expression == nil && ["A","D"].contains(part.direction ?? ""),"invalid primary key column or direction")
            if let prefix=part.prefix {
                try require(prefix > 0 && column.width.map { prefix <= $0 } == true,"invalid primary key prefix")
            } else {
                try require(!type.base.hasSuffix("text") && !type.base.hasSuffix("blob"),"TEXT/BLOB primary key requires a prefix")
            }
        }
    }
    func primaryKeyCovers(_ names:[String]) -> Bool {
        let parts=Array(effectivePrimaryKeyParts.prefix(names.count))
        return SQLIdentifier.equal(parts.compactMap(\.column),names) && parts.allSatisfy { $0.prefix == nil && $0.direction == "A" }
    }
}
extension DDLParser {
    func primaryKeyAction(_ parts:[ApplyIndexPart]) throws -> AlterAction {
        try require(parts.allSatisfy{$0.column != nil && $0.expression == nil},"primary key cannot contain an expression")
        if parts.allSatisfy({$0.prefix == nil && $0.direction == "A"}) {return .primaryKey(parts.compactMap(\.column))}
        return .primaryKeyParts(parts)
    }
}
