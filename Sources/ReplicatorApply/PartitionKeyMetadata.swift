import Foundation
import MySQLSyntax

/// I_S.PARTITIONS omits the KEY hash algorithm. Read it only during schema
/// discovery/verification, and retain it in the same cached and durable schema.
enum PartitionKeyMetadata {
    static func applying(_ sql:Data,to partitions:[ApplyPartition]) throws -> [ApplyPartition] {
        let tokens=try DDLTokens.lex(sql,sqlMode:1 << 20,nativeMetadata:true)
        let clause:SQLPartitionClause
        do {
            guard let parsed=try SQLPartitionClause.fromCreateTable(tokens) else {throw ApplyError("missing partition definition in native metadata")}
            clause=parsed
        } catch let error as SQLSyntaxError {throw ApplyError(error.message)}
        return try partitions.map { original in
            var result=original
            try require(result.method == clause.method.name,"native partition method differs from information_schema")
            result.keyAlgorithm=clause.method.algorithm == 1 ? 1 : nil
            if let children=result.subpartitions {
                guard let sub=clause.subpartition else {throw ApplyError("missing native subpartition KEY metadata")}
                result.subpartitions=try children.map {
                    try require($0.method == sub.name,"native subpartition method differs from information_schema")
                    return .init(name:$0.name,method:$0.method,expression:$0.expression,keyAlgorithm:sub.algorithm == 1 ? 1 : nil)
                }
            } else {try require(clause.subpartition == nil,"unexpected native subpartitions")}
            return result
        }
    }
}

enum PartitionMaintenanceResult {
    /// Admin SQL uses result rows for errors, even when the wire command succeeds.
    static func validate(_ messages:[(String?,String?)]) throws {
        try require(!messages.isEmpty,"partition maintenance returned no result")
        var complete=false
        for (type,text) in messages {
            guard let type,let text else {throw ApplyError("incomplete partition maintenance result")}
            switch type.lowercased() {
            case "note","warning":break
            case "status":
                try require(["OK","Table is already up to date"].contains(text),"target partition maintenance failed: "+text)
                complete=true
            default:throw ApplyError("target partition maintenance failed: "+text)
            }
        }
        try require(complete,"partition maintenance did not confirm completion")
    }
}
