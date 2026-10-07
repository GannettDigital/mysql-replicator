import Foundation

/// Complete parsing for table/database DDL. Stored object bodies are parsed by
/// the target server, using a connection without CLIENT_MULTI_STATEMENTS.
struct DDLParser {
    var tokens: [DDLToken]
    var index = 0
    var engine = "MyISAM"
    let database: String?
    var compatibility = CompatibilityPolicy()
    var defaultUTF8MB4Collation: UInt32 = 255
    var edits: [DDLSQLEdit] = []
    init(_ data: Data, database: String?, sqlMode: UInt64 = 0) throws {
        self.database = database; tokens = try DDLTokens.lex(data,sqlMode:sqlMode)
    }
    func isNext(_ word: String) -> Bool { index < tokens.count && tokens[index].keyword == word }
    mutating func take(_ word: String) -> Bool { if isNext(word) { index += 1; return true }; return false }
    mutating func expect(_ word: String) throws { try require(take(word),"unsupported DDL: expected "+word) }
    mutating func identifier() throws -> String {
        try require(index < tokens.count,"missing DDL identifier")
        let token = tokens[index]; index += 1
        try require(token.literal == nil && (token.identifier || token.text.utf8.allSatisfy(DDLTokens.word)),"invalid DDL identifier")
        _ = try quoted(token.text); return token.text
    }
    mutating func name() throws -> TableName {
        let first = try identifier()
        if take(".") { return TableName(database:first,table:try identifier()) }
        guard let database, !database.isEmpty else { throw ApplyError("unqualified DDL object without default database") }
        return TableName(database:database,table:first)
    }
    mutating func number() throws -> Int {
        let value = try identifier()
        guard value.utf8.allSatisfy({(48...57).contains($0)}), let n = Int(value) else { throw ApplyError("invalid DDL integer") }
        return n
    }
    mutating func parenthesized() throws -> [DDLToken] {
        try expect("("); let start = index; var depth = 1
        while index < tokens.count {
            if isNext("(") { depth += 1 }
            if isNext(")") { depth -= 1; if depth == 0 { let value = Array(tokens[start..<index]); index += 1; return value } }
            index += 1
        }
        throw ApplyError("unbalanced DDL parentheses")
    }
    mutating func defaultValue() throws -> String? {
        if take("NULL") { return nil }
        if take("CURRENT_TIMESTAMP") {
            if take("(") { let precision = try number(); try require(precision <= 6,"invalid timestamp precision"); try expect(")"); return precision == 0 ? "CURRENT_TIMESTAMP" : "CURRENT_TIMESTAMP(\(precision))" }
            return "CURRENT_TIMESTAMP"
        }
        if index < tokens.count, let value = tokens[index].literal { index += 1; return value }
        let sign = take("-") ? "-" : (take("+") ? "+" : "")
        try require(index < tokens.count && !tokens[index].text.isEmpty && tokens[index].text.utf8.allSatisfy({(48...57).contains($0)}),"invalid numeric default")
        var value = tokens[index].text; index += 1
        if take(".") {
            try require(index < tokens.count && tokens[index].text.utf8.allSatisfy({(48...57).contains($0)}),"invalid decimal default")
            value += "."+tokens[index].text; index += 1
        }
        return sign+value
    }
    mutating func column() throws -> (ApplyColumn,Bool) {
        let name = try identifier(); var base = try identifier().lowercased()
        if base == "integer" { base = "int" }
        if base == "numeric" || base == "dec" { base = "decimal" }
        var type = base
        if ["enum","set"].contains(base) {
            let labels = try parenthesized()
            try require(!labels.isEmpty && labels.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element.literal != nil : $0.element.keyword == "," } && labels.count % 2 == 1,"invalid ENUM/SET labels")
            try require(labels.allSatisfy { $0.literal?.unicodeScalars.allSatisfy { $0.value <= 0xffff } ?? true },"DDL ENUM/SET supplementary-plane labels cannot be verified from MySQL COLUMN_TYPE metadata")
            // information_schema escapes backslash/control bytes independently
            // of the creation session's NO_BACKSLASH_ESCAPES mode.
            type += "("+labels.map { token in
                guard let value = token.literal else { return "," }
                return "'"+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\0",with:"\\0").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"'",with:"''")+"'"
            }.joined()+")"
        } else if take("(") {
            var values = [try number()]
            if take(",") { values.append(try number()) }; try expect(")")
            if ["tinyint","smallint","mediumint","int","bigint","year"].contains(base) {
                try require(values.count == 1 && (base != "year" || values[0] == 4),"unsupported display width")
            } else {
                if base == "decimal" && values.count == 1 { values.append(0) }
                if !(["time","datetime","timestamp"].contains(base) && values == [0]) { type += "("+values.map(String.init).joined(separator:",")+")" }
            }
        } else if base == "decimal" { type += "(10,0)" }
        else if base == "char" || base == "binary" { type += "(1)" }
        if take("UNSIGNED") { type += " unsigned" }
        let parsed: DMLColumnType
        do { parsed = try DMLColumnType(type) }
        catch { throw ApplyError("unsupported DDL column type: \(type)") }
        var column = ApplyColumn(name:name,type:type,nullable:true,collation:nil)
        var charsetEnd: Int?
        var primary = false, seen: Set<String> = []
        while index < tokens.count {
            let attribute: String
            if take("NOT") { try expect("NULL"); column.nullable = false; attribute = "nullability" }
            else if take("NULL") { column.nullable = true; attribute = "nullability" }
            else if take("PRIMARY") { try expect("KEY"); primary = true; attribute = "primary" }
            else if take("DEFAULT") { column.defaultValue = try defaultValue(); attribute = "default" }
            else if take("AUTO_INCREMENT") { column.extra = "auto_increment"; column.nullable = false; attribute = "extra" }
            else if take("ON") { try expect("UPDATE"); guard let value = try defaultValue(), value.hasPrefix("CURRENT_TIMESTAMP") else { throw ApplyError("unsupported ON UPDATE expression") }; column.extra = "on update "+value; attribute = "extra" }
            else if take("CHARACTER") { try expect("SET"); column.characterSet = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; attribute = "charset" }
            else if take("COLLATE") { column = withCollation(column,try collationName()); attribute = "collation" }
            else if isNext("GENERATED") || isNext("AS") {
                if take("GENERATED") { _ = take("ALWAYS") }; try expect("AS")
                column.generationExpression = try DDLExpression.canonical(parenthesized())
                column.extra = take("STORED") ? "STORED GENERATED" : "VIRTUAL GENERATED"; _ = take("VIRTUAL"); attribute = "extra"
            } else { break }
            try require(seen.insert(attribute).inserted,"duplicate DDL column attribute")
        }
        if let collation = charsetDefault(column.characterSet,collation:column.collation,at:charsetEnd) { column = withCollation(column,collation) }
        if primary { column.nullable = false }
        try require(!seen.contains("default") || column.defaultValue != nil || column.nullable,"DEFAULT NULL on nonnullable DDL column")
        try require(!column.isGenerated || !seen.contains("default"),"generated columns cannot have defaults")
        column.defaultValue = try normalizedDefault(column.defaultValue,type:parsed)
        if !parsed.isText { try column.validate() }
        return (column,primary)
    }
    private func withCollation(_ c: ApplyColumn,_ collation: String) -> ApplyColumn {
        var copy = ApplyColumn(name:c.name,type:c.type,nullable:c.nullable,collation:collation,characterSet:c.characterSet,defaultValue:c.defaultValue,extra:c.extra)
        copy.generationExpression = c.generationExpression; return copy
    }
    mutating func placement() throws -> ColumnPlacement? {
        if take("FIRST") { return .first }; if take("AFTER") { return .after(try identifier()) }; return nil
    }
    mutating func keyParts() throws -> [ApplyIndexPart] {
        try expect("("); var parts: [ApplyIndexPart] = []
        repeat {
            let column = try identifier(); var prefix: Int?
            if take("(") { prefix = try number(); try require(prefix! > 0,"invalid index prefix"); try expect(")") }
            _ = take("ASC"); parts.append(ApplyIndexPart(column:column,prefix:prefix))
            try require(parts.count <= 16,"index part limit exceeded")
        } while take(",")
        try expect(")"); return parts
    }
    mutating func indexDefinition() throws -> ApplyIndex {
        let unique = take("UNIQUE")
        if unique { _ = take("KEY") || take("INDEX") } else { try require(take("INDEX") || take("KEY"),"expected INDEX or KEY") }
        let explicitName = isNext("(") ? nil : try identifier()
        let using = take("USING"); if using { try expect("BTREE") }
        let parts = try keyParts()
        if take("USING") { try require(!using,"duplicate index type"); try expect("BTREE") }
        return ApplyIndex(name:explicitName ?? parts[0].column,unique:unique,parts:parts)
    }
    mutating func databaseDefinition(conditional: Bool = false) throws -> CreateDatabase {
        var charsetEnd: Int?
        let name = try identifier(); var charset: String?, collation: String?, seen: Set<String> = []
        while index < tokens.count && !isNext(";") {
            _ = take("DEFAULT"); let option: String
            if take("CHARACTER") { try expect("SET"); _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
            else if take("CHARSET") { _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
            else if take("COLLATE") { _ = take("="); collation = try collationName(); option = "collation" }
            else { throw ApplyError("unsupported DATABASE option") }
            try require(seen.insert(option).inserted,"duplicate DATABASE option")
        }
        collation = charsetDefault(charset,collation:collation,at:charsetEnd)
        return CreateDatabase(name:name,ifNotExists:conditional,characterSet:charset,collation:collation)
    }
    mutating func parse() throws -> DDLStatement {
        if let object = try objectStatement() { return object }
        let result: DDLStatement
        if take("CREATE") {
            if isNext("INDEX") || isNext("UNIQUE") {
                let unique = take("UNIQUE"); try expect("INDEX"); let key = try identifier()
                let using = take("USING"); if using { try expect("BTREE") }; try expect("ON")
                let table = try name(), parts = try keyParts()
                if take("USING") { try require(!using,"duplicate index type"); try expect("BTREE") }
                result = .indexes(table,.add(ApplyIndex(name:key,unique:unique,parts:parts)))
            } else if take("DATABASE") || take("SCHEMA") {
                let conditional = take("IF"); if conditional { try expect("NOT"); try expect("EXISTS") }
                result = .createDatabase(try databaseDefinition(conditional:conditional))
            } else {
                try expect("TABLE"); let conditional = take("IF"); if conditional { try expect("NOT"); try expect("EXISTS") }
                let table = try name()
                if take("LIKE") { result = .createLike(table,try name(),ifNotExists:conditional) }
                else { result = try createTable(table,conditional:conditional) }
            }
        } else if take("ALTER") {
            if take("DATABASE") || take("SCHEMA") {
                let definition = try databaseDefinition()
                try require(definition.characterSet != nil || definition.collation != nil,"ALTER DATABASE requires encoding options")
                result = .alterDatabase(definition)
            } else {
                try expect("TABLE"); let table = try name(); var actions: [AlterAction] = []
                repeat {
                    if take("ALGORITHM") { _ = take("="); try require(["DEFAULT","COPY","INPLACE"].contains(try identifier().uppercased()),"unsupported ALTER algorithm") }
                    else if take("LOCK") { _ = take("="); try require(["DEFAULT","NONE","SHARED","EXCLUSIVE"].contains(try identifier().uppercased()),"unsupported ALTER lock") }
                    else { actions.append(try alterAction()) }
                } while take(",")
                try require(!actions.isEmpty,"ALTER requires an operation")
                result = Self.statement(table,actions)
            }
        } else if take("RENAME") {
            try expect("TABLE"); var renames: [TableRename] = []
            repeat {
                let from = try name(); try expect("TO"); let to = try name()
                try require(from.database == to.database && from != to && (renames.first?.from.database ?? from.database) == from.database,"DDL rename requires distinct names in one database")
                renames.append(TableRename(from:from,to:to))
                try require(renames.count <= 64,"DDL rename pair limit exceeded")
            } while take(",")
            result = renames.count == 1 ? .rename(renames[0].from,renames[0].to) : .renameMany(renames)
        } else if take("DROP") {
            if take("DATABASE") || take("SCHEMA") {
                let conditional = take("IF"); if conditional { try expect("EXISTS") }
                result = .dropDatabase(try identifier(),ifExists:conditional)
            } else if take("INDEX") { let key = try identifier(); try expect("ON"); result = .indexes(try name(),.drop(key)) }
            else {
                try expect("TABLE"); let conditional = take("IF"); if conditional { try expect("EXISTS") }
                let table = try name(); result = conditional ? .dropIfPresent(table) : .drop(table)
            }
        } else if take("TRUNCATE") { _ = take("TABLE"); result = .truncate(try name()) }
        else { throw ApplyError("unsupported DDL statement") }
        try end(); return result
    }
    mutating func end() throws {
        _ = take(";"); try require(index == tokens.count,"unsupported trailing DDL clause or additional statement")
    }
    static func statement(_ table: TableName,_ actions: [AlterAction]) -> DDLStatement {
        if actions.count == 1 {
            switch actions[0] {
            case .add(let c,let p): return .add(table,c,p)
            case .modify(let old,let c,let p) where old == c.name: return .modify(table,c,p)
            case .drop(let c): return .dropColumn(table,c)
            case .indexes(let change): return .indexes(table,change)
            default: break
            }
        }
        if actions.count == 2, case .indexes(.drop(let name)) = actions[0], case .indexes(.add(let key)) = actions[1] { return .indexes(table,.replace(name,key)) }
        return .alter(table,actions)
    }
    mutating func createTable(_ name: TableName,conditional: Bool) throws -> DDLStatement {
        try expect("("); var columns: [ApplyColumn] = [], key: [String]?, indexes: [ApplyIndex] = []
        repeat {
            try require(!isNext("FOREIGN"),"foreign keys are unsupported by the DDL contract")
            if take("PRIMARY") {
                try expect("KEY"); let parts = try keyParts(); try require(key == nil && parts.allSatisfy{$0.prefix == nil},"invalid DDL primary key"); key = parts.map(\.column)
            } else if isNext("INDEX") || isNext("KEY") || isNext("UNIQUE") { indexes.append(try indexDefinition()) }
            else {
                let (column,primary) = try column(); columns.append(column)
                try require(columns.count <= 256,"DDL column limit exceeded")
                if primary { try require(key == nil,"multiple DDL primary keys"); key = [column.name] }
            }
        } while take(",")
        try expect(")")
        var charsetEnd: Int?
        var charset: String?, collation: String?, options: Set<String> = [], engine = DDLEngine.omitted
        while index < tokens.count && !isNext(";") && !isNext("PARTITION") {
            let option: String
            if take("ENGINE") {
                _ = take("="); option = "engine"
                if take(self.engine.uppercased()) { engine = self.engine == "MyISAM" ? .myISAM : .innoDB }
                else if index < tokens.count && tokens[index].literal?.uppercased() == self.engine.uppercased() { index += 1; engine = self.engine == "MyISAM" ? .myISAM : .innoDB }
                else if index < tokens.count && tokens[index].literal?.uppercased() == "DEFAULT" { index += 1; engine = .defaultEngine }
                else { throw ApplyError("explicit engine is outside the \(self.engine) DDL contract (no engine rewriting)") }
            } else if take("AUTO_INCREMENT") { _ = take("="); _ = try number(); option = "auto_increment" }
            else {
                _ = take("DEFAULT")
                if take("CHARACTER") { try expect("SET"); _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
                else if take("CHARSET") { _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
                else if take("COLLATE") { _ = take("="); collation = try collationName(); option = "collation" }
                else { throw ApplyError("unsupported CREATE TABLE option") }
            }
            try require(options.insert(option).inserted,"duplicate CREATE TABLE option")
        }
        collation = charsetDefault(charset,collation:collation,at:charsetEnd)
        guard let key else { throw ApplyError("DDL CREATE requires a primary key") }
        for i in columns.indices where key.contains(columns[i].name) { columns[i].nullable = false }
        var schema = ApplyTable(database:name.database,table:name.table,columns:columns,primaryKeyColumns:key,defaultCharacterSet:charset,defaultCollation:collation,secondaryIndexes:indexes.sorted{$0.name.lowercased() < $1.name.lowercased()})
        if take("PARTITION") { schema.partitions = try partitionDefinition() }
        return conditional ? .createIfAbsent(schema,engine) : .create(schema,engine)
    }
    mutating func alterAction() throws -> AlterAction {
        if take("ADD") {
            if take("PRIMARY") { try expect("KEY"); let parts = try keyParts(); try require(parts.allSatisfy{$0.prefix == nil},"primary prefix unsupported"); return .primaryKey(parts.map(\.column)) }
            if isNext("INDEX") || isNext("KEY") || isNext("UNIQUE") { return .indexes(.add(try indexDefinition())) }
            if take("PARTITION") { return .partition(.add(try partitionItems(method:"",expression:""))) }
            _ = take("COLUMN"); let (c,primary) = try column(); try require(!primary,"ADD inline primary key is unsupported; use ADD PRIMARY KEY")
            try require(c.nullable || c.defaultValue != nil || c.isGenerated,"ADD NOT NULL requires an explicit default or generated expression")
            return .add(c,try placement() ?? .last)
        }
        if isNext("MODIFY") || isNext("CHANGE") {
            let change = take("CHANGE"); if !change { try expect("MODIFY") }; _ = take("COLUMN")
            let old = change ? try identifier() : nil, (c,primary) = try column()
            try require(!primary,"MODIFY/CHANGE cannot declare primary-key membership")
            return .modify(old ?? c.name,c,try placement())
        }
        if take("DROP") {
            if take("PRIMARY") { try expect("KEY"); return .primaryKey(nil) }
            if take("INDEX") || take("KEY") { return .indexes(.drop(try identifier())) }
            if take("PARTITION") { return .partition(.drop(try partitionNames())) }
            _ = take("COLUMN"); return .drop(try identifier())
        }
        if take("ALTER") {
            _ = take("COLUMN"); let column = try identifier()
            if take("SET") { try expect("DEFAULT"); return .defaultValue(column,try defaultValue()) }
            try expect("DROP"); try expect("DEFAULT"); return .defaultValue(column,nil)
        }
        if take("RENAME") { try require(take("INDEX") || take("KEY"),"unsupported ALTER RENAME operation"); let old = try identifier(); try expect("TO"); return .indexes(.rename(old,try identifier())) }
        if take("PARTITION") { return .partition(.replace(try partitionDefinition())) }
        if take("REMOVE") { try expect("PARTITIONING"); return .partition(.remove) }
        if take("TRUNCATE") { try expect("PARTITION"); return .partition(.truncate(try partitionNames())) }
        if take("REORGANIZE") { try expect("PARTITION"); let names = try partitionNames(); try expect("INTO"); return .partition(.reorganize(names,try partitionItems(method:"",expression:""))) }
        if take("COALESCE") { try expect("PARTITION"); return .partition(.coalesce(try number())) }
        if take("EXCHANGE") { try expect("PARTITION"); let partition = try identifier(); try expect("WITH"); try expect("TABLE"); let table = try name(); if take("WITH") { try expect("VALIDATION") }; return .partition(.exchange(partition,table)) }
        throw ApplyError("unsupported ALTER TABLE operation")
    }
}

func normalizedDefault(_ value: String?,type: DMLColumnType) throws -> String? {
    guard var value else { return nil }
    if type.base.hasSuffix("text") || type.base.hasSuffix("blob") { throw ApplyError("MySQL 5.7 TEXT/BLOB columns cannot have non-NULL defaults") }
    if type.base == "year" {
        guard let year=Int(value),year == 0 || (1901...2155).contains(year) else {throw ApplyError("YEAR default must be zero or a four-digit year")}
        return String(format:"%04d",year)
    }
    if type.integerBits != nil {
        if type.unsigned, let number = UInt64(value) { return String(number) }
        guard let number = Int64(value) else { throw ApplyError("invalid integer default") }
        return String(number)
    }
    if type.base == "decimal" {
        try require(value.range(of:#"^[+-]?[0-9]+(?:\.[0-9]+)?$"#,options:.regularExpression) != nil,"invalid decimal default")
        let parts = value.split(separator:".",omittingEmptySubsequences:false), scale = type.arguments[1]
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        try require(fraction.count <= scale,"decimal default would require rounding")
        let negative = parts[0].hasPrefix("-")
        let digits = parts[0].drop(while:{$0 == "+" || $0 == "-"}).drop(while:{$0 == "0"})
        let integral = digits.isEmpty ? "0" : String(digits)
        let nonzero = integral != "0" || fraction.contains{$0 != "0"}
        value = (negative && nonzero ? "-" : "")+integral+(scale == 0 ? "" : "."+fraction+String(repeating:"0",count:scale-fraction.count))
    }
    if type.base == "binary" {
        try require(value.utf8.count <= type.arguments[0],"binary default exceeds column width")
        value += String(repeating:"\0",count:type.arguments[0]-value.utf8.count)
    }
    if ["time","datetime","timestamp"].contains(type.base) && !value.hasPrefix("CURRENT_TIMESTAMP") {
        let canonical = try type.canonicalTemporal(value)
        value = type.fraction == 0 ? String(canonical.dropLast(7)) : String(canonical.dropLast(6-type.fraction))
    }
    return value
}
