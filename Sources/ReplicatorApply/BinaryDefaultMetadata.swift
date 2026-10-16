import Foundation

enum BinaryDefaultMetadata {
    static func resolved(_ column: ApplyColumn, bytes: Data) throws -> ApplyColumn {
        let type = try DMLColumnType(column)
        try require(["binary", "varbinary"].contains(type.base), "invalid binary default type")
        try type.validate(.binary(bytes))
        var result = column
        result.numericDefaultLiteral = nil
        // Keep the old schema format when UTF-8 can represent the exact bytes.
        result.defaultValue = String(data: bytes, encoding: .utf8)
        result.binaryDefaultBytes = result.defaultValue == nil ? bytes : nil
        try result.validate()
        return result
    }
}

extension TargetSession {
    func discoverBinaryDefault(_ column: ApplyColumn, table: TableName) throws -> ApplyColumn {
        try BinaryDefaultMetadata.resolved(column, bytes: readStoredDefaultBytes(column, table: table, utf8: false))
    }

    func resolveBinaryDefault(_ column: ApplyColumn, database: String, sqlMode: UInt64) throws -> ApplyColumn {
        guard let bytes = column.binaryDefaultBytes ?? column.defaultValue.map({ Data($0.utf8) }) else {
            try column.validate()
            return column
        }
        let type = try DMLColumnType(column)
        try require(
            ["binary", "varbinary"].contains(type.base), "binary defaults require separate support for this type")
        let literal: String
        if column.numericDefaultLiteral == true, let value = column.defaultValue {
            try require(
                value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                "invalid numeric binary default")
            literal = value
        } else {
            literal = SQLByteLiteral.sql(bytes)
        }
        return try withMetadataMode(String(contract.ddlSQLMode(sqlMode) & ~(1 << 20))) {
            try withMetadataScratch(database: database) { name in
                _ = try query(
                    "CREATE TEMPORARY TABLE " + name + " (v " + column.type + (column.nullable ? " NULL" : " NOT NULL")
                        + " DEFAULT " + literal + ") ENGINE=InnoDB", textProtocol: true)
                _ = try query("INSERT INTO " + name + " VALUES(DEFAULT)", textProtocol: true)
                guard let value = try query("SELECT CAST(v AS BINARY) AS v FROM " + name).0.first?.column("v")?.buffer
                else { throw ApplyError("missing native binary default") }
                return try BinaryDefaultMetadata.resolved(column, bytes: Data(value.readableBytesView))
            }
        }
    }
}
