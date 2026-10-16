import Foundation

/// A lookup key, distinct from the table's declared PRIMARY KEY. Unique-key
/// choices are saved with each schema version so recovery cannot choose anew.
struct RowIdentity: Codable, Equatable {
    enum Kind: String, Codable { case primary, unique, fullRow }
    let kind: Kind
    let index: String
    let columns: [String]
    static func == (a:Self,b:Self) -> Bool {
        a.kind == b.kind && SQLIdentifier.equal(a.index,b.index) && SQLIdentifier.equal(a.columns,b.columns)
    }
}

extension ApplyTable {
    var eligibleUniqueIdentities: [RowIdentity] {
        secondaryIndexes.sorted { SQLIdentifier.key($0.name) < SQLIdentifier.key($1.name) }.compactMap { index in
            guard index.unique && index.type == "BTREE" && !index.parts.isEmpty && index.parts.count <= 16 else { return nil }
            var names:[String]=[]
            for part in index.parts {
                guard part.prefix == nil && part.expression == nil, let name=part.column,
                      let column=columns.first(where:{SQLIdentifier.equal($0.name,name)}),
                      !column.nullable && !column.isGenerated,
                      let type=try? DMLColumnType(column), !type.isSpatial && type.base != "json"
                        && !type.base.hasSuffix("text") && !type.base.hasSuffix("blob") else { return nil }
                names.append(column.name)
            }
            return RowIdentity(kind:.unique,index:index.name,columns:names)
        }
    }
    var rowIdentity: RowIdentity? {
        if let savedRowIdentity { return savedRowIdentity }
        if !primaryKeyColumns.isEmpty { return RowIdentity(kind:.primary,index:"PRIMARY",columns:primaryKeyColumns) }
        return eligibleUniqueIdentities.first ?? fullRowIdentity
    }
    var fullRowIdentity: RowIdentity {
        RowIdentity(kind:.fullRow,index:"",columns:columns.filter { !$0.isGenerated }.map(\.name))
    }
    var usesFullRowIdentity: Bool { rowIdentity?.kind == .fullRow }
    func validateRowIdentity() throws {
        guard let identity=rowIdentity else { throw ApplyError("table requires a primary key or a full nonnullable unique key of supported base scalar columns") }
        if identity.kind == .fullRow {
            try require(primaryKeyColumns.isEmpty && identity == fullRowIdentity && !identity.columns.isEmpty,"saved full-row identity differs from base columns")
        } else if primaryKeyColumns.isEmpty {
            try require(identity.kind == .unique && eligibleUniqueIdentities.contains(identity),"saved row identity does not match an eligible unique index")
        } else {
            try require(identity == RowIdentity(kind:.primary,index:"PRIMARY",columns:primaryKeyColumns),"saved row identity differs from primary key")
        }
    }
}
