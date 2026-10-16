import Foundation

enum TextDefaultMetadata {
    static func resolved(_ column:ApplyColumn,utf8:Data) throws -> ApplyColumn {
        let type=try DMLColumnType(column)
        try require(["char","varchar"].contains(type.base),"invalid text default type")
        guard var text=String(data:utf8,encoding:.utf8) else { throw ApplyError("native text default is not UTF-8") }
        // CHAR removes trailing U+0020 on read unless PAD_CHAR_TO_FULL_LENGTH
        // is set. Use the same schema representation in either session mode.
        if type.base == "char" { while text.last == " " { text.removeLast() } }
        var result=column
        result.defaultValue=text
        result.binaryDefaultBytes=nil
        result.numericDefaultLiteral=nil
        try result.validate()
        return result
    }
}

extension TargetSession {
    func discoverTextDefault(_ column:ApplyColumn,table:TableName) throws -> ApplyColumn {
        try TextDefaultMetadata.resolved(column,utf8:readStoredDefaultBytes(column,table:table,utf8:true))
    }

    func resolveTextDefault(_ column:ApplyColumn,database:String,sqlMode:UInt64) throws -> ApplyColumn {
        guard column.hasDefaultValue else { try column.validate();return column }
        let type=try DMLColumnType(column)
        try require(["char","varchar"].contains(type.base),"invalid text default probe")
        let literal:String
        if let bytes=column.binaryDefaultBytes { literal=SQLByteLiteral.sql(bytes) }
        else if let value=column.defaultValue {
            if column.numericDefaultLiteral == true {
                try require(value.range(of:#"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,"invalid numeric text default")
                literal=value
            } else { literal=ChoiceMetadata.literal(value) }
        } else { throw ApplyError("missing text default literal") }
        return try withMetadataMode(String(contract.ddlSQLMode(sqlMode) & ~(1 << 20))) {
            try withMetadataScratch(database:database) { name in
                let definition=try column.type+" CHARACTER SET "+quoted(column.characterSet!)+" COLLATE "+quoted(column.collation!)+(column.nullable ? " NULL" : " NOT NULL")
                _ = try query("CREATE TEMPORARY TABLE "+name+" (v "+definition+" DEFAULT "+literal+") ENGINE=InnoDB",textProtocol:true)
                _ = try query("INSERT INTO "+name+" VALUES(DEFAULT)",textProtocol:true)
                guard let value=try query("SELECT CONVERT(v USING utf8mb4) AS v FROM "+name).0.first?.column("v")?.buffer else { throw ApplyError("missing native text default") }
                return try TextDefaultMetadata.resolved(column,utf8:Data(value.readableBytesView))
            }
        }
    }
}
