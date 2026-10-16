import Foundation
import MySQLNIO
import ReplicatorCodec

/// Full before-image matching for tables without a usable unique key. Each
/// UPDATE/DELETE uses LIMIT 1. Text comparison must ignore SQL collation rules.
enum FullRowPredicate {
    static func scalar(_ type:DMLColumnType,name:String) -> String {
        if type.base == "decimal" { return name+"<=>CAST(? AS DECIMAL(\(type.arguments[0]),\(type.arguments[1])))" }
        if type.isChoice || type.bitWidth != nil { return "CAST(\(name) AS UNSIGNED)<=>?" }
        if type.interpretation == .utf8 || type.interpretation.isEncodedText || type.interpretation == .binary {
            return "CAST(\(name) AS BINARY)<=>CAST(\(type.sqlValue("?")) AS BINARY)"
        }
        return type.sqlKeyColumn(name)+"<=>?"
    }
    static func make(table:ApplyTable,types:[DMLColumnType],values:[DecodedValue],
                     compatibility:CompatibilityPolicy,bind:(DecodedValue)throws->MySQLData) throws -> JSONSQLValue {
        try require(values.count == table.keyIndexes.count,"full-row lookup value count differs")
        var predicates:[String]=[],binds:[MySQLData]=[]
        for (index,value) in zip(table.keyIndexes,values) {
            let name=try quoted(table.columns[index].name)
            if value == .null {
                // MySQL 8.4 can treat nullable UNIQUE equality with a bound
                // NULL as a single-row lookup. A literal IS NULL scans all copies.
                predicates.append(name+" IS NULL")
            } else if case .json(let source)=value {
                let document=try compatibility.targetJSON(source)
                // Compare structure and values without recreating opaque SQL
                // scalars. This also distinguishes JSON null from SQL NULL.
                for field in try document.matchFields() {
                    predicates.append("JSON_TYPE(JSON_EXTRACT(\(name),?))=?")
                    binds += [.init(string:field.path),.init(string:field.type)]
                    if let count=field.count {
                        predicates.append("JSON_LENGTH(JSON_EXTRACT(\(name),?))=?")
                        binds += [.init(string:field.path),try bind(.unsigned(UInt64(count)))]
                    }
                    if let text=field.text {
                        predicates.append(field.floating
                            ? "(JSON_UNQUOTE(JSON_EXTRACT(\(name),?))+0e0)=(?+0e0)"
                            : "CAST(JSON_UNQUOTE(JSON_EXTRACT(\(name),?)) AS BINARY)=CAST(? AS BINARY)")
                        binds += [.init(string:field.path),.init(string:text)]
                        if field.floating, Double(text) == 0 {
                            predicates.append("ATAN2(JSON_UNQUOTE(JSON_EXTRACT(\(name),?)),-1)"+(text.hasPrefix("-") ? "<0" : ">=0"))
                            binds.append(.init(string:field.path))
                        }
                    }
                }
            } else {
                predicates.append(scalar(types[index],name:name));binds.append(try bind(value))
                // SQL equality treats both zeros as equal. Native record
                // comparison preserves their sign bit. ATAN2 retains that sign.
                let negativeZero:Bool?
                switch value {
                case .float32(let bits) where bits & 0x7fffffff == 0: negativeZero=bits != 0
                case .float64(let bits) where bits & 0x7fffffffffffffff == 0: negativeZero=bits != 0
                default: negativeZero=nil
                }
                if let negativeZero { predicates.append("ATAN2(\(name),-1)"+(negativeZero ? "<0" : ">=0")) }
            }
        }
        try require(!predicates.isEmpty,"empty full-row predicate")
        return .init(sql:predicates.joined(separator:" AND "),binds:binds)
    }
}
