import Foundation

enum DDLExpressionMetadata {
    static func canonical(_ value:String,mysql84:Bool) throws -> String {
        // 8.4 dd_table.cc uses convert_and_print -> String::print for I_S
        // generation_expression_utf8, default_value_utf8 and index expressions.
        // Undo that outer escaping once, then parse the SQL literal escaping.
        var bytes=Array(value.utf8)
        if mysql84 {
            var decoded:[UInt8]=[],i=0
            let escapes:[UInt8:UInt8]=[92:92,48:0,39:39,110:10,114:13,90:26]
            while i < bytes.count {
                if bytes[i] == 92 {
                    i += 1
                    guard i < bytes.count,let byte=escapes[bytes[i]] else { throw ApplyError("invalid MySQL 8.4 expression metadata escape") }
                    decoded.append(byte)
                } else { decoded.append(bytes[i]) }
                i += 1
            }
            bytes=decoded
        }
        return try DDLExpression.canonical(DDLTokens.lex(Data(bytes)))
    }
}

extension TargetContract {
    func validateSchemaFeatures(_ table:ApplyTable) throws {
        for column in table.columns where column.defaultExpression != nil {
            try require(versionPrefix != "5.7.","target MySQL 5.7 does not support expression defaults: column \(column.name) (requires MySQL 8.0.13 or later)")
        }
        for index in table.secondaryIndexes {
            for part in index.parts {
                if index.type == "BTREE",let name=part.column,
                   let column=table.columns.first(where:{SQLIdentifier.equal($0.name,name)}),try DMLColumnType(column).isSpatial {
                    try require(versionPrefix == "5.7.","target MySQL 8.4 does not support geometry BTREE prefix indexes: index \(index.name), column \(name); native error 1089")
                }
                if part.expression != nil {
                    try require(versionPrefix != "5.7.","target MySQL 5.7 does not support functional index \(index.name) (requires MySQL 8.0.13 or later)")
                }
                if let name=part.column,let column=table.columns.first(where:{SQLIdentifier.equal($0.name,name)}),column.extra == "VIRTUAL GENERATED" {
                    try require(engine == "InnoDB","target \(engine) does not support indexes on VIRTUAL generated columns: index \(index.name), column \(name); use a STORED generated column")
                }
            }
        }
    }
}
