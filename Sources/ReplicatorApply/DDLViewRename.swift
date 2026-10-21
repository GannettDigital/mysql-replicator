import Foundation

/// View metadata belongs to the DDL journal, not the row-schema cache.
struct ViewDefinition: Codable, Equatable {
    let database: String
    let table: String
    let attributes: [String: String]
    var name: TableName { TableName(database: database, table: table) }
    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.attributes.count == b.attributes.count
            && a.attributes.allSatisfy { key, value in b.attributes[key].map { SQLTextBytes.equal(value, $0) } == true }
    }
    func renamed(to destination: TableName) throws -> Self {
        try require(
            SQLTextBytes.equal(database, destination.database),
            "DDL RENAME cannot move a view to another database (ER_FORBID_SCHEMA_CHANGE)")
        return Self(database: destination.database, table: destination.table, attributes: attributes)
    }
}

struct ViewTransition: Codable {
    let before: ViewDefinition?
    let after: ViewDefinition?
}

enum RenameObject {
    case table(ApplyTable)
    case view(ViewDefinition)
    var table: ApplyTable? {
        if case .table(let value) = self { return value }
        return nil
    }
    var view: ViewDefinition? {
        if case .view(let value) = self { return value }
        return nil
    }
    func renamed(to name: TableName) throws -> Self {
        switch self {
        case .table(let value): return .table(value.renamed(to: name))
        case .view(let value): return .view(try value.renamed(to: name))
        }
    }
}

extension TargetSession {
    func readView(_ name: TableName) throws -> ViewDefinition? {
        // IS_UPDATABLE is derived. A base-table rename in the same statement can
        // change it without changing the saved view definition.
        let fields = [
            "VIEW_DEFINITION", "DEFINER", "SECURITY_TYPE", "CHECK_OPTION", "CHARACTER_SET_CLIENT",
            "COLLATION_CONNECTION",
        ]
        let rows = try metadataQuery(
            "SELECT " + fields.joined(separator: ",")
                + " FROM information_schema.VIEWS WHERE TABLE_SCHEMA=? AND TABLE_NAME=?",
            [.init(string: name.database), .init(string: name.table)]
        ).0
        guard let row = rows.first else { return nil }
        var attributes: [String: String] = [:]
        for field in fields {
            guard let value = row.column(field)?.string else {
                throw ApplyError("cannot read target view metadata: \(field)")
            }
            attributes[field] = value
        }
        return ViewDefinition(database: name.database, table: name.table, attributes: attributes)
    }
}
