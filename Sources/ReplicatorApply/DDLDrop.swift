import Foundation
import ReplicatorCodec

extension TargetSession {
    func prepareDrops(_ names:[TableName],conditional:Bool,source:QueryControl,context:QuerySessionContext) throws -> PreparedDDL {
        var changes:[SchemaTransition]=[], seen=Set<SQLNameKey>()
        for name in names where seen.insert(name.identity).inserted {
            if try tableExists(name) {
                let before=try readSchema(database:name.database,name:name.table)
                if let cached=discovered[name.identity] { try require(before == cached,"target schema drift before DROP") }
                changes.append(SchemaTransition(before:before,after:nil))
            } else {
                try require(discovered[name.identity] == nil,"target schema disappeared before DROP")
                try require(conditional,"DDL DROP target is absent: \(name.database).\(name.table)")
            }
        }
        // MySQL 5.7 can remove some tables before it reports an error. Save all
        // initial schemas, then issue the original list once. Failure leaves
        // the intent pending; no table or GTID is marked complete locally.
        let plan=try prepareForeignKeyTransitions(PreparedDDL(statement:.dropMany(names,ifExists:conditional),before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self),additional:changes),foreignKeyChecks:context.foreignKeyChecks)
        try setDDLSession(context,source:source)
        return plan
    }
}
