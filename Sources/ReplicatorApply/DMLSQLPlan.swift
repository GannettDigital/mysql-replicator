import Foundation

/// Session-local SQL for one validated schema version. Never persisted as
/// recovery authority; source DDL invalidates it along with prepared statements.
struct DMLSQLPlan {
    let table: ApplyTable
    let columnTypes: [DMLColumnType]
    let keyIndexes: [Int]
    let select: String
    let insert: String
    private let insertPrefix: String
    private let insertTuple: String
    private let updatePrefix: String
    private let writeNames: [String]
    private let updateWhere: String
    func insertSQL(rows: Int) -> String {
        insertPrefix + Array(repeating:insertTuple,count:rows).joined(separator:",")
    }
    func insertSQL(expressions:[[String]]) -> String {
        insertPrefix+expressions.map { row in "("+zip(writeIndexes,row).map { columnTypes[$0.0].sqlWriteValue($0.1) }.joined(separator:",")+")" }.joined(separator:",")
    }
    func updateSQL(expressions:[String]) -> String {
        precondition(expressions.count == writeIndexes.count)
        let pairs=zip(writeNames,expressions).enumerated().map { index,pair in pair.0+"="+columnTypes[writeIndexes[index]].sqlWriteValue(pair.1) }
        return updatePrefix+pairs.joined(separator:",")+updateWhere
    }
    let writeIndexes: [Int]
    let generatedIndexes: [Int]
    let enumIndexes: [Int]
    let update: String
    let delete: String

    init(_ table: ApplyTable) throws {
        self.table = table
        let columnTypes = try DMLTablePlan(table).columnTypes
        self.columnTypes = columnTypes
        keyIndexes = table.keyIndexes
        enumIndexes = columnTypes.indices.filter { columnTypes[$0].base == "enum" }
        let names = try table.columns.map { try quoted($0.name) }
        writeIndexes = table.columns.indices.filter { !table.columns[$0].isGenerated }
        generatedIndexes = table.columns.indices.filter { table.columns[$0].isGenerated }
        let writes = writeIndexes.map { names[$0] }
        writeNames = writes
        let columns = writes.joined(separator:",")
        let sqlName = try table.sqlName
        let predicate = keyIndexes.map { columnTypes[$0].sqlKeyColumn(names[$0]) + "=" + columnTypes[$0].sqlValue("?") }.joined(separator:" AND ")
        let reads = zip(columnTypes,names).map { type,name in
            if type.interpretation.isEncodedText { return "CAST(\(name) AS BINARY) AS \(name)" }
            if type.isChoice || type.bitWidth != nil { return "CAST(\(name) AS UNSIGNED) AS \(name)" }
            return [.decimal,.temporal,.json].contains(type.interpretation) ? "CAST(\(name) AS CHAR) AS \(name)" : name
        }.joined(separator:",")
        select = "SELECT \(reads) FROM \(sqlName) WHERE \(predicate)"
        insertPrefix = "INSERT INTO \(sqlName) (\(columns)) VALUES "
        insertTuple = "(\(writeIndexes.map { columnTypes[$0].sqlWriteValue("?") }.joined(separator:",")))"
        insert = insertPrefix + insertTuple
        updatePrefix = "UPDATE \(sqlName) SET "
        updateWhere = " WHERE \(predicate)"
        update = "UPDATE \(sqlName) SET \(writeIndexes.map { names[$0] + "=" + columnTypes[$0].sqlWriteValue("?") }.joined(separator:",")) WHERE \(predicate)"
        delete = "DELETE FROM \(sqlName) WHERE \(predicate)"
    }
}
