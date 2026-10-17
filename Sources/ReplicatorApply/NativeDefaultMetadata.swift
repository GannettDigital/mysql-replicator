import Foundation

extension TargetSession {
    func readStoredDefaultBytes(_ column:ApplyColumn,table:TableName,utf8:Bool) throws -> Data {
        // A NOT NULL field on the missing side of an outer join reads as NULL,
        // including DEFAULT(field). Clone only the native field, with no rows,
        // then let MySQL evaluate its exact default in the private table.
        // This uses the same native metadata path as ENUM/SET discovery.
        if !column.nullable {
            return try withMetadataScratch(database:table.database) { name in
                _ = try query("CREATE TEMPORARY TABLE "+name+" ENGINE=InnoDB AS SELECT "+quoted(column.name)+" AS v FROM "+table.sql+" LIMIT 0",textProtocol:true)
                _ = try query("INSERT INTO "+name+" VALUES(DEFAULT)",textProtocol:true)
                let expression=utf8 ? "CONVERT(v USING utf8mb4)" : "CAST(v AS BINARY)"
                guard let value=try query("SELECT "+expression+" AS v FROM "+name).0.first?.column("v")?.buffer else { throw ApplyError("missing cloned column default") }
                return Data(value.readableBytesView)
            }
        }
        // I_S can lose bytes. DEFAULT reads the native field's stored default.
        // The false outer join returns a result even when the table is empty.
        let projection=try "DEFAULT(t."+quoted(column.name)+")"
        let expression=utf8 ? "CONVERT("+projection+" USING utf8mb4)" : "CAST("+projection+" AS BINARY)"
        let sql=try "SELECT "+expression+" AS v FROM "+table.sql+" AS t RIGHT JOIN (SELECT 1) AS p ON FALSE LIMIT 1"
        guard let value=try query(sql).0.first?.column("v")?.buffer else { throw ApplyError("missing stored column default") }
        return Data(value.readableBytesView)
    }

    func resolveDecimalDefault(_ column:ApplyColumn,database:String,sqlMode:UInt64) throws -> ApplyColumn {
        guard let value=column.defaultValue,let numeric=column.numericDefaultLiteral else { return column }
        let type=try DMLColumnType(column)
        try require(type.base == "decimal","invalid DECIMAL default probe")
        let literal:String
        if numeric {
            try require(value.range(of:#"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,"invalid numeric DECIMAL default")
            literal=value
        } else { literal=ChoiceMetadata.literal(value) }
        // MySQL resolves numeric and string constants through different Item
        // paths. Let the target perform its own conversion and rounding.
        return try withMetadataMode(String(contract.ddlSQLMode(sqlMode) & ~(1 << 20))) {
            try withMetadataScratch(database:database) { name in
                let nullability=column.nullable ? " NULL" : " NOT NULL"
                _ = try query("CREATE TEMPORARY TABLE "+name+" (v "+column.type+nullability+" DEFAULT "+literal+") ENGINE=InnoDB",textProtocol:true)
                _ = try query("INSERT INTO "+name+" VALUES(DEFAULT)",textProtocol:true)
                guard let stored=try scalar("SELECT CAST(v AS CHAR) AS v FROM "+name) else { throw ApplyError("missing native DECIMAL default") }
                var result=column
                result.defaultValue=try normalizedDefault(stored,type:type)
                result.numericDefaultLiteral=nil
                try result.validate()
                return result
            }
        }
    }

    // Callers supply an integer mode mask or an escaped internal string literal.
    // The parser has decoded SQL literals, so callers clear NO_BACKSLASH_ESCAPES.
    func withMetadataMode<T>(_ modeLiteral:String,body:() throws -> T) throws -> T {
        guard let previous=try scalar("SELECT @@SESSION.sql_mode AS v") else { throw ApplyError("missing SQL mode before metadata probe") }
        _ = try query("SET SESSION sql_mode="+modeLiteral)
        let outcome:Result<T,Error>
        do { outcome = .success(try body()) } catch { outcome = .failure(error) }
        do { _ = try query("SET SESSION sql_mode=?",[.init(string:previous)]) }
        catch {
            try? connection.close().wait()
            throw ApplyError("cannot restore SQL mode after metadata probe: \(error)")
        }
        return try outcome.get()
    }

    func withMetadataScratch<T>(database:String,body:(String) throws -> T) throws -> T {
        try withMetadataTable(database:database) { try body($0.sql) }
    }

    func withMetadataTable<T>(database:String,body:(TableName) throws -> T) throws -> T {
        let table=TableName(database:database,table:"_replicator_metadata_"+UUID().uuidString.replacingOccurrences(of:"-",with:""))
        let name=try table.sql
        let outcome:Result<T,Error>
        do { outcome = .success(try body(table)) } catch { outcome = .failure(error) }
        do { _ = try query("DROP TEMPORARY TABLE IF EXISTS "+name,textProtocol:true) }
        catch {
            try? connection.close().wait()
            throw ApplyError("cannot remove temporary metadata table: \(error)")
        }
        return try outcome.get()
    }
}
