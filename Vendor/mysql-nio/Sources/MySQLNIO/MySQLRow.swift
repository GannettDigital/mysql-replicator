import NIOCore

public struct MySQLRow: CustomStringConvertible, Sendable {
    public let format: MySQLData.Format
    public let columnDefinitions: [MySQLProtocol.ColumnDefinition41]
    public let values: [ByteBuffer?]
    
    public var description: String {
        var desc: [String] = []
        for (column, value) in zip(self.columnDefinitions, self.values) {
            let data = MySQLData(
                type: column.columnType,
                format: self.format,
                buffer: value,
                isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
            )
            desc.append(column.name.debugDescription+": "+data.description)
        }
        return "["+desc.joined(separator:", ")+"]"
    }
    
    public init(
        format: MySQLData.Format,
        columnDefinitions: [MySQLProtocol.ColumnDefinition41],
        values: [ByteBuffer?]
    ) {
        self.format = format
        self.columnDefinitions = columnDefinitions
        self.values = values
    }
    
    public func column(_ name: String, table: String? = nil) -> MySQLData? {
        for (column, value) in zip(self.columnDefinitions, self.values) {
            if column.name.utf8.elementsEqual(name.utf8) && (table.map { column.table.utf8.elementsEqual($0.utf8) } ?? true) {
                return .init(
                    type: column.columnType,
                    format: self.format,
                    buffer: value,
                    isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
                )
            }
        }
        return nil
    }
}
