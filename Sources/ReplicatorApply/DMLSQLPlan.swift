import Foundation

/// Session-local SQL for one validated schema version. Never persisted as
/// recovery authority; source DDL invalidates it along with prepared statements.
struct DMLSQLPlan {
    let table: ApplyTable
    let keyIndex: Int
    let select: String
    let insert: String
    let update: String
    let delete: String

    init(_ table: ApplyTable) throws {
        self.table = table
        keyIndex = table.keyIndex
        let names = try table.columns.map { try quoted($0.name) }
        let columns = names.joined(separator:",")
        let sqlName = try table.sqlName
        let predicate = try quoted(table.primaryKey) + "=?"
        select = "SELECT \(columns) FROM \(sqlName) WHERE \(predicate)"
        insert = "INSERT INTO \(sqlName) (\(columns)) VALUES (\(Array(repeating:"?",count:names.count).joined(separator:",")))"
        update = "UPDATE \(sqlName) SET \(names.map { $0 + "=?" }.joined(separator:",")) WHERE \(predicate)"
        delete = "DELETE FROM \(sqlName) WHERE \(predicate)"
    }
}
