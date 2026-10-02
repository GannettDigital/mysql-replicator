import Foundation

/// Session-local SQL for one validated schema version. Never persisted as
/// recovery authority; source DDL invalidates it along with prepared statements.
struct DMLSQLPlan {
    let table: ApplyTable
    let keyIndex: Int
    let select: String
    let insert: String
    private let insertPrefix: String
    private let insertTuple: String
    func insertSQL(rows: Int) -> String {
        insertPrefix + Array(repeating:insertTuple,count:rows).joined(separator:",")
    }
    let update: String
    let delete: String

    init(_ table: ApplyTable) throws {
        self.table = table
        keyIndex = table.keyIndex
        let names = try table.columns.map { try quoted($0.name) }
        let columns = names.joined(separator:",")
        let sqlName = try table.sqlName
        let predicate = try quoted(table.primaryKey) + "=?"
        let reads = try zip(table.columns,names).map { column,name in
            let type = try DMLColumnType(column.type)
            return [.decimal,.temporal].contains(type.interpretation) ? "CAST(\(name) AS CHAR) AS \(name)" : name
        }.joined(separator:",")
        select = "SELECT \(reads) FROM \(sqlName) WHERE \(predicate)"
        insertPrefix = "INSERT INTO \(sqlName) (\(columns)) VALUES "
        insertTuple = "(\(Array(repeating:"?",count:names.count).joined(separator:",")))"
        insert = insertPrefix + insertTuple
        update = "UPDATE \(sqlName) SET \(names.map { $0 + "=?" }.joined(separator:",")) WHERE \(predicate)"
        delete = "DELETE FROM \(sqlName) WHERE \(predicate)"
    }
}
