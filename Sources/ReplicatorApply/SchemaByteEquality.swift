import Foundation

extension ApplyIndexPart {
    public static func == (a:Self,b:Self) -> Bool {
        SQLIdentifier.equal(a.column,b.column) && a.prefix == b.prefix && a.direction == b.direction
    }
}
extension ApplyIndex {
    public static func == (a:Self,b:Self) -> Bool {
        SQLTextBytes.equal(a.name,b.name) && a.unique == b.unique && a.parts == b.parts && a.type == b.type
    }
}
extension ApplyPartition {
    public static func == (a:Self,b:Self) -> Bool {
        SQLTextBytes.equal(a.name,b.name) && a.method == b.method
            && SQLTextBytes.equal(a.expression,b.expression) && SQLTextBytes.equal(a.description,b.description)
    }
}
extension ApplyForeignKey {
    public static func == (a:Self,b:Self) -> Bool {
        SQLTextBytes.equal(a.name,b.name) && a.child == b.child && a.parent == b.parent
            && SQLIdentifier.equal(a.columns,b.columns) && SQLIdentifier.equal(a.referencedColumns,b.referencedColumns)
            && a.onUpdate == b.onUpdate && a.onDelete == b.onDelete
    }
}
extension ApplyTable {
    public static func == (a:Self,b:Self) -> Bool {
        a.identity == b.identity && a.columns == b.columns && SQLIdentifier.equal(a.primaryKeyColumns,b.primaryKeyColumns)
            && a.defaultCharacterSet == b.defaultCharacterSet && a.defaultCollation == b.defaultCollation
            && a.secondaryIndexes == b.secondaryIndexes && a.partitions == b.partitions && a.foreignKeys == b.foreignKeys
    }
}
