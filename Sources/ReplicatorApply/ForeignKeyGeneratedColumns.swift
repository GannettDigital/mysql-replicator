import Foundation

/// Rules shared by the qualified 5.7 and 8.4 InnoDB targets. Stored generated
/// columns can participate; virtual columns cannot. The server checks additional
/// restrictions on base columns of stored expressions during DDL execution.
enum ForeignKeyGeneratedColumns {
    static func validateParent(_ column: ApplyColumn) throws {
        try require(
            column.extra != "VIRTUAL GENERATED",
            "InnoDB foreign key cannot reference virtual generated column \(column.name)")
    }
    static func validateChild(_ column: ApplyColumn, key: ApplyForeignKey) throws {
        try require(
            column.extra != "VIRTUAL GENERATED",
            "InnoDB foreign key \(key.name) cannot use virtual generated child column \(column.name)")
        guard column.isGenerated else { return }
        try require(
            key.onDelete != "SET NULL",
            "InnoDB stored generated FK column \(column.name) does not support ON DELETE SET NULL")
        try require(
            !["CASCADE", "SET NULL"].contains(key.onUpdate),
            "InnoDB stored generated FK column \(column.name) does not support ON UPDATE \(key.onUpdate)")
    }
}
