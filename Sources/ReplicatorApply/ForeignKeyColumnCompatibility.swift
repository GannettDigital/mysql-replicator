import Foundation

/// InnoDB cmp_cols_are_equal compares storage categories. It does not require
/// identical SQL type text. Index validation separately excludes prefix keys.
enum ForeignKeyColumnCompatibility {
    private enum Storage: Equatable {
        case text(String), binary, integer(Int, Bool), float, double, geometry
    }
    static func matches(_ child: ApplyColumn, _ parent: ApplyColumn) throws -> Bool {
        try storage(child) == storage(parent)
    }
    private static func storage(_ column: ApplyColumn) throws -> Storage {
        let type = try DMLColumnType(column)
        if let bits = type.integerBits { return .integer(bits / 8, type.unsigned) }
        if type.base == "year" { return .integer(1, true) }
        if type.base == "date" { return .integer(3, false) }
        if type.base == "enum" { return .integer(type.labels.count < 256 ? 1 : 2, true) }
        if type.base == "set" {
            let bytes = (type.labels.count + 7) / 8
            return .integer(bytes > 4 ? 8 : bytes, true)
        }
        if type.base == "float" { return .float }
        if type.base == "double" { return .double }
        if type.isSpatial { return .geometry }
        if type.isText && type.characterSet != "binary" {
            let collation = column.collation ?? ""
            let identity =
                CharacterSetRegistry.columnCollation(named: collation).map { String($0.id) }
                ?? type.characterSet + ":" + collation
            return .text(identity)
        }
        // Modern temporal types, NEWDECIMAL and BIT use DATA_FIXBINARY.
        // BINARY/VARBINARY and binary BLOBs compare in the same category.
        return .binary
    }
}
