import Foundation

/// Native ALTER checks the original partition function only when it survives.
/// A replacement function uses final column names; do not rewrite its SQL.
enum PartitionColumnDependencies {
    static func validate(_ table:ApplyTable,actions:[AlterAction]) throws {
        if actions.contains(where: {
            switch $0 {
            case .partition(.replace),.partition(.remove):return true
            default:return false
            }
        }) {return}
        for action in actions {
            let name:String,operation:String
            switch action {
            case .modify(let old,let column,_) where !SQLIdentifier.equal(old,column.name):name=old;operation="CHANGE"
            case .drop(let old):name=old;operation="DROP"
            default:continue
            }
            for partition in table.partitions {
                let expressions=[partition.expression]+(partition.subpartitions ?? []).map(\.expression)
                // KEY() follows the primary key. It has no explicit dependency.
                if try expressions.contains(where:{if $0.isEmpty {return false};return try DDLExpression.references(name,in:$0)}) {
                    throw ApplyError("cannot "+operation+" column "+name+": unchanged partition expression depends on it; replace partitioning or REMOVE PARTITIONING in the same ALTER")
                }
            }
        }
    }
}
