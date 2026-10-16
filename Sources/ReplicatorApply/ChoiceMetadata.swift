import Foundation
import MySQLNIO

/// COLUMN_TYPE can replace supplementary labels with '?'. Keep the native
/// label bytes separately when the displayed UTF-8 type cannot describe them.
enum ChoiceMetadata {
    static func literal(_ value:String) -> String {
        "'"+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\0",with:"\\0").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"'",with:"''")+"'"
    }
    static func resolved(_ column:ApplyColumn,labels:[Data],display:[String],defaultValue:String?,defaultOrdinal:UInt64?,defaultBytes:Data? = nil) throws -> ApplyColumn {
        let parsed=try DMLColumnType(column)
        try require(parsed.isChoice && labels.count == parsed.labels.count && display.count == labels.count,"incomplete native ENUM/SET label metadata")
        let binary=parsed.characterSet == "binary"
        try require((defaultOrdinal != nil) == column.hasDefaultValue && (binary ? defaultBytes != nil : defaultValue != nil) == column.hasDefaultValue,"incomplete ENUM/SET default metadata")
        var result=column
        result.type=parsed.base+"("+(binary ? labels.map(SQLByteLiteral.sql) : display.map(literal)).joined(separator:",")+")"
        result.defaultValue=binary ? nil : defaultValue
        result.choiceDefaultBytes=binary ? defaultBytes : nil
        result.numericDefaultLiteral=nil
        // Retain the old schema shape for UTF-8 BMP labels. Old saved schemas
        // can still pass drift checks. Exact metadata is needed for other bytes.
        let exact = !["utf8mb3","utf8mb4"].contains(parsed.characterSet) || display.contains { $0.unicodeScalars.contains { $0.value > 0xffff } }
        result.choiceLabels = exact ? labels : nil
        let ambiguousDefault = parsed.base == "set" && labels.contains(Data())
            || Set(labels).count != labels.count
        result.choiceDefaultOrdinal = exact || ambiguousDefault ? defaultOrdinal : nil
        try result.validate()
        return result
    }
}

extension TargetSession {
    func discoverChoiceColumn(_ column:ApplyColumn,table:TableName) throws -> ApplyColumn {
        // Native non-strict DDL can retain duplicate labels. Clone the existing
        // native type without applying stricter CREATE validation to that type.
        try withMetadataMode(ChoiceMetadata.literal(EnumZeroWrite.writeMode)) {
            try withMetadataScratch(database:table.database) { name in
                _ = try query("CREATE TEMPORARY TABLE "+name+" ENGINE=InnoDB AS SELECT CAST(0 AS UNSIGNED) AS o,"+quoted(column.name)+" AS v FROM "+table.sql+" LIMIT 0",textProtocol:true)
                var input=column
                if column.characterSet == "binary" {
                    // 5.7 I_S can truncate COLUMN_TYPE at an invalid UTF-8 byte.
                    // The cloned native field still has the complete type library.
                    let base=column.type.hasPrefix("enum(") ? "enum" : "set"
                    let count=try binaryChoiceCount(base:base,name:name)
                    input.type=base+"("+Array(repeating:"X''",count:count).joined(separator:",")+")"
                }
                return try readChoiceScratch(input,name:name)
            }
        }
    }

    private func binaryChoiceCount(base:String,name:String) throws -> Int {
        _ = try query("INSERT INTO "+name+" (o,v) VALUES(0,0)",textProtocol:true)
        var low=1,high=base == "enum" ? 65535 : 64
        while low < high {
            let middle=(low+high+1)/2
            let number=base == "enum" ? UInt64(middle) : UInt64(1) << (middle-1)
            _ = try query("UPDATE "+name+" SET v=\(number)",textProtocol:true)
            let actual=try scalar("SELECT CAST(CAST(v AS UNSIGNED) AS CHAR) AS v FROM "+name)
            if actual == String(number) { low=middle } else { high=middle-1 }
        }
        _ = try query("DELETE FROM "+name,textProtocol:true)
        return low
    }

    func resolveChoiceColumn(_ column:ApplyColumn,database:String,sqlMode:UInt64) throws -> ApplyColumn {
        try withMetadataMode(String(contract.ddlSQLMode(sqlMode) & ~(1 << 20))) {
            try withMetadataScratch(database:database) { name in
                var definition=try column.type+" CHARACTER SET "+quoted(column.characterSet!)+" COLLATE "+quoted(column.collation!)
                definition += column.nullable ? " NULL" : " NOT NULL"
                if let bytes=column.choiceDefaultBytes {
                    definition += " DEFAULT "+SQLByteLiteral.sql(bytes)
                } else if let value=column.defaultValue {
                    if column.numericDefaultLiteral == true {
                        try require(value.range(of:#"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,"invalid numeric ENUM/SET default")
                        definition += " DEFAULT "+value
                    } else { definition += " DEFAULT "+ChoiceMetadata.literal(value) }
                }
                _ = try query("CREATE TEMPORARY TABLE "+name+" (o BIGINT UNSIGNED,v "+definition+") ENGINE=InnoDB",textProtocol:true)
                return try readChoiceScratch(column,name:name)
            }
        }
    }

    private func readChoiceScratch(_ column:ApplyColumn,name:String) throws -> ApplyColumn {
        let type=try DMLColumnType(column),count=type.labels.count
        // Bounded statements also cover the native ENUM limit of 65,535 labels.
        for start in stride(from:0,to:count,by:256) {
            let values=(start..<min(start+256,count)).map { i in
                let ordinal=type.base == "enum" ? UInt64(i+1) : UInt64(1) << i
                return "(\(i+1),\(ordinal))"
            }.joined(separator:",")
            _ = try query("INSERT INTO "+name+" (o,v) VALUES "+values,textProtocol:true)
        }
        if column.hasDefaultValue { _ = try query("INSERT INTO "+name+" (o,v) VALUES (0,DEFAULT)",textProtocol:true) }
        let rows=try query("SELECT o,CAST(v AS BINARY) AS raw_value,CAST(v AS CHAR CHARACTER SET utf8mb4) AS display_value,CAST(CAST(v AS UNSIGNED) AS CHAR) AS ordinal_value FROM "+name+" ORDER BY o").0
        var labels:[Data]=[],display:[String]=[],defaultValue:String?,defaultOrdinal:UInt64?,defaultBytes:Data?
        for row in rows {
            guard let index=row.column("o")?.int,let buffer=row.column("raw_value")?.buffer,
                  let number=row.column("ordinal_value")?.string.flatMap(UInt64.init) else { throw ApplyError("incomplete ENUM/SET probe result") }
            let bytes=Data(buffer.readableBytesView)
            let text:String
            if type.characterSet == "binary" { text=SQLByteLiteral.sql(bytes) }
            else {
                guard let value=row.column("display_value")?.string else { throw ApplyError("native ENUM/SET label cannot be represented as UTF-8") }
                text=value
            }
            if index == 0 { defaultValue=text;defaultOrdinal=number;defaultBytes=bytes }
            else {
                try require(index == labels.count+1,"ENUM/SET probe label order differs")
                let expected=type.base == "enum" ? UInt64(index) : UInt64(1) << (index-1)
                try require(number == expected,"ENUM/SET probe ordinal differs")
                labels.append(bytes);display.append(text)
            }
        }
        return try ChoiceMetadata.resolved(column,labels:labels,display:display,defaultValue:defaultValue,defaultOrdinal:defaultOrdinal,defaultBytes:defaultBytes)
    }
}
