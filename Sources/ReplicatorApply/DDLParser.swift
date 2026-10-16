import Foundation
import MySQLSyntax
import ReplicatorCodec

/// Complete parsing for table/database DDL. Stored object bodies are parsed by
/// the target server, using a connection without CLIENT_MULTI_STATEMENTS.
struct DDLParser {
    var tokens: [DDLToken]
    var index = 0
    var numericDefault = false
    var byteDefault:Data? = nil
    var literalDefaultBytes:Data? = nil
    var lowerCaseTableNames = 0
    func storedTableName(_ name:String) -> String { lowerCaseTableNames == 1 ? SQLIdentifier.lowercase(name) : name }
    var engine = "MyISAM"
    var targetVersion = "5.7."
    let expressionSQLMode: UInt64
    let realAsFloat: Bool
    let database: String?
    var compatibility = CompatibilityPolicy()
    var defaultUTF8MB4Collation: UInt32 = 255
    var edits: [DDLSQLEdit] = []
    var partitionLiteralCharset="utf8mb4"
    var nativeRules=NativeReplicationRules(profile:.mysql84To57MyISAM)
    var ignoredCheckCount=0
    var ignoredForeignKeyMatchCount=0
    var tableEncodingRanges: [(Range<Int>, DDLTableEncoding)] = []
    init(_ data: Data, database: String?, sqlMode: UInt64 = 0) throws {
        expressionSQLMode=sqlMode
        realAsFloat = sqlMode & 1 != 0
        self.database = database; tokens = try DDLTokens.lex(data,sqlMode:sqlMode)
    }
    init(query:QueryControl, tokens:[DDLToken]? = nil) throws {
        let context=try query.statusVariables.isEmpty ? nil : QuerySessionContext(query:query)
        if tokens == nil,query.sql.contains(where: { $0 >= 128 }),let context {
            let charset=CharacterSetRegistry.collation(id:context.clientCharset)?.characterSet
            try require(charset == "utf8mb3" || charset == "utf8mb4", "non-UTF-8 Query-event text needs charset-aware parsing: character_set_client=\(DDLQueryContextDiagnostic.collation(context.clientCharset))")
        }
        partitionLiteralCharset=context.flatMap { CharacterSetRegistry.collation(id:$0.connectionCollation)?.characterSet } ?? "utf8mb4"
        expressionSQLMode=context?.sqlMode ?? 0
        realAsFloat=(context?.sqlMode ?? 0) & 1 != 0
        database=query.database
        self.tokens=try tokens ?? DDLTokens.lex(query.sql,sqlMode:context?.sqlMode ?? 0)
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
    mutating func name(foldTable:Bool = true) throws -> TableName {
        let first = try identifier()
        let db:String, table:String
        if take(".") { db=first;table=try identifier() }
        else {
            guard let database, !database.isEmpty else { throw ApplyError("unqualified DDL object without default database") }
            db=database;table=first
        }
        return TableName(database:storedTableName(db),table:foldTable ? storedTableName(table) : table)
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
    mutating func defaultValue(bit: Bool = false) throws -> String? {
        numericDefault = false;byteDefault=nil;literalDefaultBytes=nil
        if index < tokens.count && !bit {
            let length=["X","B"].contains(tokens[index].keyword) ? 2 : 1
            if index+length <= tokens.count,let value=try SQLByteLiteral.parse(Array(tokens[index..<index+length])) {
                index += length;byteDefault=value;return nil
            }
        }
        if take("NULL") { return nil }
        if bit, take("B") {
            guard index < tokens.count, let digits=tokens[index].literal,
                  !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "1" }),
                  let value=UInt64(digits,radix:2) else { throw ApplyError("invalid BIT default literal") }
            index += 1
            return String(value)
        }
        if bit, index < tokens.count, tokens[index].text.hasPrefix("0b") {
            let digits=tokens[index].text.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "1" }),
                  let value=UInt64(digits,radix:2) else { throw ApplyError("invalid BIT default literal") }
            index += 1
            return String(value)
        }
        if take("CURRENT_TIMESTAMP") {
            if take("(") { let precision = try number(); try require(precision <= 6,"invalid timestamp precision"); try expect(")"); return precision == 0 ? "CURRENT_TIMESTAMP" : "CURRENT_TIMESTAMP(\(precision))" }
            return "CURRENT_TIMESTAMP"
        }
        if index < tokens.count, let value = tokens[index].literal { literalDefaultBytes=tokens[index].literalBytes; index += 1; return value }
        let sign = take("-") ? "-" : (take("+") ? "+" : "")
        try require(index < tokens.count,"missing numeric default")
        var value=tokens[index].text; index += 1
        if take(".") {
            try require(index < tokens.count,"missing fractional default")
            value += "."+tokens[index].text; index += 1
        }
        if value.hasSuffix("e") || value.hasSuffix("E") {
            value += take("-") ? "-" : (take("+") ? "+" : "")
            try require(index < tokens.count,"missing default exponent")
            value += tokens[index].text; index += 1
        }
        try require(value.range(of:#"^[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,"invalid numeric default")
        numericDefault = true
        return sign+value
    }
    mutating func column() throws -> (ApplyColumn,Bool) {
        let name = try identifier(); var base = try identifier().lowercased()
        if base == "geomcollection" { base = "geometrycollection" }
        if base == "real" { base = realAsFloat ? "float" : "double" }
        if base == "double" { _ = take("PRECISION") }
        if base == "integer" { base = "int" }
        if base == "numeric" || base == "dec" { base = "decimal" }
        var type = base
        var inputChoiceBytes: [Data]?
        var integerDisplayWidth: Int?
        if ["enum","set"].contains(base) {
            let tokens=try parenthesized()
            var groups:[[DDLToken]]=[[]]
            for token in tokens {
                if token.keyword == "," { groups.append([]) } else { groups[groups.count-1].append(token) }
            }
            if groups.contains(where: { $0.count == 1 && $0[0].literalBytes != nil }) {
                inputChoiceBytes=try groups.map { group in
                    if group.count == 1,let text=group[0].literal { return group[0].literalBytes ?? Data(text.utf8) }
                    guard let bytes=try SQLByteLiteral.parse(group) else { throw ApplyError("invalid ENUM/SET label literal") }
                    return bytes
                }
            }
            let labels=try groups.map { group -> String in
                if group.count == 1,let literal=group[0].literal { return ChoiceMetadata.literal(literal) }
                guard let bytes=try SQLByteLiteral.parse(group) else { throw ApplyError("invalid ENUM/SET label literal") }
                return SQLByteLiteral.sql(bytes)
            }
            type += "("+labels.joined(separator:",")+")"
        } else if take("(") {
            var values = [try number()]
            if take(",") { values.append(try number()) }; try expect(")")
            if base == "float", values.count == 1 {
                try require((0...53).contains(values[0]),"invalid FLOAT binary precision")
                base = values[0] <= 24 ? "float" : "double"; type = base
            } else if ["tinyint","smallint","mediumint","int","bigint","year"].contains(base) {
                try require(values.count == 1 && (base != "year" || values[0] == 4),"unsupported display width")
                integerDisplayWidth = values[0]
            } else {
                if base == "decimal" && values.count == 1 { values.append(0) }
                if !(["time","datetime","timestamp"].contains(base) && values == [0]) { type += "("+values.map(String.init).joined(separator:",")+")" }
            }
        } else if base == "decimal" { type += "(10,0)" }
        else if base == "char" || base == "binary" || base == "bit" { type += "(1)" }
        var unsigned=false, zerofill=false
        while true {
            if take("UNSIGNED") { unsigned=true }
            else if take("ZEROFILL") { unsigned=true; zerofill=true }
            else if take("SIGNED") { continue }
            else { break }
        }
        if base != "year" {
            if zerofill, let defaultWidth=["tinyint":3,"smallint":5,"mediumint":8,"int":10,"bigint":20][base] {
                let width=integerDisplayWidth.flatMap { $0 == 0 ? nil : $0 } ?? defaultWidth
                type=base+"(\(width))"
            }
            if unsigned { type += " unsigned" }
            if zerofill { type += " zerofill" }
        }
        let parsed: DMLColumnType
        do { parsed = try DMLColumnType(type) }
        catch { throw ApplyError("unsupported DDL column type: \(type)",code:.unsupportedColumnType) }
        var column = ApplyColumn(name:name,type:type,nullable:true,collation:nil)
        column.inputChoiceBytes=inputChoiceBytes
        var charsetEnd: Int?
        var primary = false, seen: Set<String> = []
        while index < tokens.count {
            let attribute: String
            if take("NOT") { try expect("NULL"); column.nullable = false; attribute = "nullability" }
            else if take("NULL") { column.nullable = true; attribute = "nullability" }
            else if take("PRIMARY") { try expect("KEY"); primary = true; attribute = "primary" }
            else if take("DEFAULT") {
                if isNext("(") {
                    try require(targetVersion != "5.7.","target MySQL 5.7 does not support expression defaults (requires MySQL 8.0.13 or later)")
                    column.defaultExpression = try DDLExpression.canonical(parenthesized(),sqlMode:expressionSQLMode)
                    attribute = "default"
                    try require(seen.insert(attribute).inserted,"duplicate DDL column attribute")
                    continue
                }
                column.defaultValue = try defaultValue(bit:parsed.bitWidth != nil)
                column.inputDefaultBytes=literalDefaultBytes
                column.numericDefaultLiteral = (parsed.isChoice || ["decimal","binary","varbinary"].contains(parsed.base)) && column.defaultValue != nil ? numericDefault : nil
                if ["char","varchar"].contains(parsed.base) && numericDefault { column.numericDefaultLiteral=true }
                try require(byteDefault == nil || parsed.isChoice || ["binary","varbinary","char","varchar"].contains(parsed.base),"binary defaults require separate support for this type")
                if parsed.isChoice { column.choiceDefaultBytes=byteDefault }
                else { column.binaryDefaultBytes=byteDefault }
                if ["binary","varbinary"].contains(parsed.base) && !numericDefault {
                    column.binaryDefaultBytes = byteDefault ?? literalDefaultBytes ?? column.defaultValue.map { Data($0.utf8) }
                    column.inputDefaultBytes=nil
                    column.defaultValue=nil
                    column.numericDefaultLiteral=nil
                }
                attribute = "default"
            }
            else if isNext("CHECK") { try ignoredCheck(); attribute = "check" }
            else if take("COMMENT") { try consumeCommentLiteral(); attribute = "comment" }
            else if take("AUTO_INCREMENT") { column.extra = "auto_increment"; column.nullable = false; attribute = "extra" }
            else if take("ON") { try expect("UPDATE"); guard let value = try defaultValue(), value.hasPrefix("CURRENT_TIMESTAMP") else { throw ApplyError("unsupported ON UPDATE expression") }; column.extra = "on update "+value; attribute = "extra" }
            else if take("CHARACTER") { try expect("SET"); column.characterSet = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; attribute = "charset" }
            else if take("COLLATE") { column = withCollation(column,try collationName()); attribute = "collation" }
            else if isNext("GENERATED") || isNext("AS") {
                if take("GENERATED") { _ = take("ALWAYS") }; try expect("AS")
                column.generationExpression = try DDLExpression.canonical(parenthesized(),sqlMode:expressionSQLMode)
                column.extra = take("STORED") ? "STORED GENERATED" : "VIRTUAL GENERATED"; _ = take("VIRTUAL"); attribute = "extra"
            } else { break }
            try require(seen.insert(attribute).inserted,"duplicate DDL column attribute")
        }
        if let collation = charsetDefault(column.characterSet,collation:column.collation,at:charsetEnd) { column = withCollation(column,collation) }
        if primary { column.nullable = false }
        try require(!seen.contains("default") || column.hasDefaultValue || column.nullable,"DEFAULT NULL on nonnullable DDL column")
        try require(!column.isGenerated || !seen.contains("default"),"generated columns cannot have defaults")
        if column.numericDefaultLiteral == nil { column.defaultValue = try normalizedDefault(column.defaultValue,type:parsed) }
        if !parsed.isText && !["binary","varbinary"].contains(parsed.base) { column.inputDefaultBytes=nil }
        if !parsed.isText && column.numericDefaultLiteral == nil && column.binaryDefaultBytes == nil { try column.validate() }
        return (column,primary)
    }
    private func withCollation(_ c: ApplyColumn,_ collation: String) -> ApplyColumn {
        var copy = c; copy.collation = collation; return copy
    }
    mutating func placement() throws -> ColumnPlacement? {
        if take("FIRST") { return .first }; if take("AFTER") { return .after(try identifier()) }; return nil
    }
    mutating func keyParts(fulltext:Bool = false) throws -> [ApplyIndexPart] {
        try expect("("); var parts: [ApplyIndexPart] = []
        repeat {
            let column:String?, expression:String?
            var prefix:Int?
            if isNext("(") {
                try require(targetVersion != "5.7.","target MySQL 5.7 does not support functional indexes (requires MySQL 8.0.13 or later)")
                expression=try DDLExpression.canonical(parenthesized(),sqlMode:expressionSQLMode);column=nil
            } else {
                column=try identifier();expression=nil
                if take("(") { prefix=try number();try require(fulltext || prefix! > 0,"invalid index prefix");try expect(")") }
            }
            let descending=take("DESC");if !descending { _ = take("ASC") }
            // MySQL 5.7 accepts DESC but stores an ascending index.
            parts.append(ApplyIndexPart(column:column,prefix:fulltext ? nil : prefix,direction:fulltext ? nil : descending && targetVersion != "5.7." ? "D" : "A",expression:expression))
            try require(parts.count <= 16,"index part limit exceeded")
        } while take(",")
        try expect(")"); return parts
    }
    mutating func constraintName() throws -> String? {
        guard take("CONSTRAINT") else { return nil }
        let name = ["PRIMARY","UNIQUE","FOREIGN","CHECK"].contains(where:isNext) ? nil : try identifier()
        try require(engine == "InnoDB" || !isNext("FOREIGN"),"foreign keys are unsupported by the DDL contract")
        try require(isNext("PRIMARY") || isNext("UNIQUE") || isNext("FOREIGN") || isNext("CHECK"),"unsupported DDL constraint: expected PRIMARY KEY or UNIQUE")
        return name
    }
    mutating func indexDefinition(constraintName: String? = nil) throws -> ApplyIndex {
        let spatial = take("SPATIAL"),fulltext = take("FULLTEXT")
        let unique = !spatial && !fulltext && take("UNIQUE")
        if unique { _ = take("KEY") || take("INDEX") } else { try require(take("INDEX") || take("KEY"),"expected INDEX or KEY") }
        let explicitName = isNext("(") || isNext("USING") ? nil : try identifier()
        let using = take("USING"); if using { try require(!spatial && !fulltext,"SPATIAL/FULLTEXT index does not accept USING BTREE"); try expect("BTREE") }
        let parts = try keyParts(fulltext:fulltext)
        if take("USING") { try require(!using && !spatial && !fulltext,"unsupported or duplicate index type"); try expect("BTREE") }
        // Both MySQL versions prefer an explicit index name over the constraint
        // symbol, then default to the first indexed column.
        return ApplyIndex(name:explicitName ?? constraintName ?? (parts.contains { $0.expression != nil } ? "functional_index" : parts[0].column!),unique:unique,parts:parts,type:spatial ? "SPATIAL" : fulltext ? "FULLTEXT" : "BTREE",parser:try fulltextParser(fulltext),implicitName:explicitName == nil && constraintName == nil && parts.contains { $0.expression != nil } ? true : nil)
    }
    mutating func fulltextParser(_ fulltext:Bool) throws -> String? {
        guard take("WITH") else { return nil }
        try require(fulltext,"WITH PARSER requires FULLTEXT")
        try expect("PARSER");return SQLIdentifier.lowercase(try identifier())
    }
    mutating func databaseDefinition(conditional: Bool = false) throws -> CreateDatabase {
        var charsetEnd: Int?
        let name = storedTableName(try identifier()); var charset: String?, collation: String?, seen: Set<String> = []
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
            if isNext("INDEX") || isNext("UNIQUE") || isNext("SPATIAL") || isNext("FULLTEXT") {
                let spatial = take("SPATIAL"), fulltext = take("FULLTEXT"), unique = take("UNIQUE"); try require(!(spatial || fulltext) || !unique,"SPATIAL/FULLTEXT index cannot be UNIQUE"); try expect("INDEX"); let key = try identifier()
                let using = take("USING"); if using { try require(!spatial && !fulltext,"SPATIAL/FULLTEXT index does not accept USING BTREE"); try expect("BTREE") }; try expect("ON")
                let table = try name(), parts = try keyParts(fulltext:fulltext)
                if take("USING") { try require(!using && !spatial && !fulltext,"unsupported or duplicate index type"); try expect("BTREE") }
                result = .indexes(table,.add(ApplyIndex(name:key,unique:unique,parts:parts,type:spatial ? "SPATIAL" : fulltext ? "FULLTEXT" : "BTREE",parser:try fulltextParser(fulltext))))
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
                var items:[(range:Range<Int>,ignored:Bool)]=[]
                repeat {
                    let start=index, count=actions.count
                    if take("ALGORITHM") { _ = take("="); try require(["DEFAULT","COPY","INPLACE"].contains(try identifier().uppercased()),"unsupported ALTER algorithm") }
                    else if take("LOCK") { _ = take("="); try require(["DEFAULT","NONE","SHARED","EXCLUSIVE"].contains(try identifier().uppercased()),"unsupported ALTER lock") }
                    else { actions.append(try alterAction(table:table)) }
                    let ignored = actions.count > count && actions.last == .ignoredCheck
                    items.append((try itemRange(from:start),ignored))
                } while take(",") || isTableOption || isTableEncoding
                try require(!actions.isEmpty,"ALTER requires an operation")
                removeIgnoredItems(items)
                result = Self.statement(table,actions)
            }
        } else if take("RENAME") {
            try expect("TABLE"); var renames: [TableRename] = []
            repeat {
                let from = try name(); try expect("TO"); let to = try name()
                try require(from != to,"DDL rename requires distinct names")
                renames.append(TableRename(from:from,to:to))
                try require(renames.count <= 64,"DDL rename pair limit exceeded")
            } while take(",")
            result = renames.count == 1 ? .rename(renames[0].from,renames[0].to) : .renameMany(renames)
        } else if take("DROP") {
            if take("DATABASE") || take("SCHEMA") {
                let conditional = take("IF"); if conditional { try expect("EXISTS") }
                result = .dropDatabase(storedTableName(try identifier()),ifExists:conditional)
            } else if take("INDEX") { let key = try identifier(); try expect("ON"); result = .indexes(try name(),.drop(key)) }
            else {
                try expect("TABLE"); let conditional = take("IF"); if conditional { try expect("EXISTS") }
                var names = [try name()]
                while take(",") {
                    names.append(try name())
                    try require(names.count <= 64,"DDL DROP table limit exceeded")
                }
                // MySQL accepts these keywords without changing DROP behavior.
                if !take("RESTRICT") { _ = take("CASCADE") }
                result = names.count == 1 ? (conditional ? .dropIfPresent(names[0]) : .drop(names[0])) : .dropMany(names,ifExists:conditional)
            }
        } else if take("TRUNCATE") { _ = take("TABLE"); result = .truncate(try name()) }
        else { throw ApplyError("unsupported DDL statement",code:.unsupportedDDL) }
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
        var foreignKeys: [(ApplyForeignKey,String?)] = []
        var items:[(range:Range<Int>,ignored:Bool)]=[]
        repeat {
            let start=index
            let constraint = try constraintName()
            let ignored=isNext("CHECK")
            if ignored { try ignoredCheck() }
            else if isNext("FOREIGN") { foreignKeys.append(try foreignKey(table:name,constraint:constraint)) }
            else if take("PRIMARY") {
                try expect("KEY"); let parts = try keyParts(); try require(key == nil && parts.allSatisfy{$0.prefix == nil && $0.column != nil},"invalid DDL primary key"); key = parts.map { $0.column ?? "" }
            } else if isNext("INDEX") || isNext("KEY") || isNext("UNIQUE") || isNext("SPATIAL") || isNext("FULLTEXT") { indexes.append(try indexDefinition(constraintName:constraint)) }
            else {
                let (column,primary) = try column(); columns.append(column)
                try require(columns.count <= 256,"DDL column limit exceeded")
                if primary { try require(key == nil,"multiple DDL primary keys"); key = [column.name] }
            }
            items.append((try itemRange(from:start),ignored))
        } while take(",")
        removeIgnoredItems(items)
        try expect(")")
        // Native reserves explicit names before it names functional indexes.
        var named=indexes.filter { $0.implicitName == nil }
        for i in indexes.indices where indexes[i].implicitName == true {
            indexes[i]=indexes[i].resolvingName(among:named);named.append(indexes[i])
        }
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
            } else if isTableOption { option = try tableOption().name.lowercased() }
            else {
                _ = take("DEFAULT")
                if take("CHARACTER") { try expect("SET"); _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
                else if take("CHARSET") { _ = take("="); charset = try identifier().lowercased(); charsetEnd = tokens[index-1].range?.upperBound; option = "charset" }
                else if take("COLLATE") { _ = take("="); collation = try collationName(); option = "collation" }
                else { throw ApplyError("unsupported CREATE TABLE option") }
            }
            try require(options.insert(option).inserted,"duplicate CREATE TABLE option")
            if take(",") { try require(index < tokens.count && !isNext(";"),"missing CREATE TABLE option") }
        }
        collation = charsetDefault(charset,collation:collation,at:charsetEnd)
        let primaryColumns = key ?? []
        for i in columns.indices where SQLIdentifier.contains(primaryColumns,columns[i].name) { columns[i].nullable = false }
        var schema = ApplyTable(database:name.database,table:name.table,columns:columns,primaryKeyColumns:primaryColumns,defaultCharacterSet:charset,defaultCollation:collation,secondaryIndexes:indexes.sorted{SQLIdentifier.key($0.name) < SQLIdentifier.key($1.name)})
        for (key,index) in foreignKeys { schema = try schema.addingForeignKey(key,indexName:index) }
        if take("PARTITION") { schema.partitions = try partitionDefinition() }
        return conditional ? .createIfAbsent(schema,engine) : .create(schema,engine)
    }
    mutating func alterAction(table: TableName) throws -> AlterAction {
        if ["REBUILD","ANALYZE","CHECK","OPTIMIZE","REPAIR"].contains(tokens.indices.contains(index) ? tokens[index].keyword : "") {
            let end=tokens.last?.keyword == ";" ? tokens.count-1 : tokens.count
            do {
                let operation=try SQLPartitionMaintenance.parse(Array(tokens[index..<end]))
                index=end
                return .partition(.maintenance(operation))
            } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
        }
        if ["FORCE","ENABLE","DISABLE"].contains(where:isNext) {
            let end=min(tokens.count,index+(isNext("FORCE") ? 1 : 2))
            do {
                let operation=try SQLAlterMaintenance.parse(Array(tokens[index..<end]))
                index=end;return .maintenance(operation)
            } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
        }
        if isTableEncoding || isNext("CONVERT") { return .encoding(try tableEncodingChange()) }
        if isTableOption { return .tableOption(try tableOption()) }
        if take("ADD") {
            let constraint = try constraintName()
            if isNext("CHECK") { try ignoredCheck();return .ignoredCheck }
            if isNext("FOREIGN") { let (key,index) = try foreignKey(table:table,constraint:constraint); return .addForeignKey(key,index) }
            if take("PRIMARY") { try expect("KEY"); let parts = try keyParts(); try require(parts.allSatisfy{$0.prefix == nil && $0.column != nil},"primary prefix unsupported"); return .primaryKey(parts.map { $0.column ?? "" }) }
            if isNext("INDEX") || isNext("KEY") || isNext("UNIQUE") || isNext("SPATIAL") || isNext("FULLTEXT") { return .indexes(.add(try indexDefinition(constraintName:constraint))) }
            if take("PARTITION") {
                if take("PARTITIONS") { return .partition(.addHash(try number())) }
                return .partition(.add(try partitionItems(method:"",expression:"")))
            }
            _ = take("COLUMN"); let (c,primary) = try column(); try require(!primary,"ADD inline primary key is unsupported; use ADD PRIMARY KEY")
            try require(c.nullable || c.hasDefaultValue || c.isGenerated,"ADD NOT NULL requires an explicit default or generated expression")
            return .add(c,try placement() ?? .last)
        }
        if isNext("MODIFY") || isNext("CHANGE") {
            let change = take("CHANGE"); if !change { try expect("MODIFY") }; _ = take("COLUMN")
            let old = change ? try identifier() : nil, (c,primary) = try column()
            try require(!primary,"MODIFY/CHANGE cannot declare primary-key membership")
            return .modify(old ?? c.name,c,try placement())
        }
        if take("DROP") {
            if take("FOREIGN") { try require(engine == "InnoDB","foreign keys are unsupported by the DDL contract"); try expect("KEY"); return .dropForeignKey(try identifier()) }
            if take("PRIMARY") { try expect("KEY"); return .primaryKey(nil) }
            if take("INDEX") || take("KEY") { return .indexes(.drop(try identifier())) }
            if take("PARTITION") { return .partition(.drop(try partitionNames())) }
            _ = take("COLUMN"); return .drop(try identifier())
        }
        if take("ALTER") {
            _ = take("COLUMN"); let column = try identifier()
            if take("SET") { try expect("DEFAULT")
                if isNext("(") {
                    try require(targetVersion != "5.7.","target MySQL 5.7 does not support expression defaults (requires MySQL 8.0.13 or later)")
                    return .defaultExpression(column,try DDLExpression.canonical(parenthesized(),sqlMode:expressionSQLMode))
                }
                let value = try defaultValue(); return .defaultValue(column,value,numeric:numericDefault,bytes:byteDefault,literalBytes:literalDefaultBytes) }
            try expect("DROP"); try expect("DEFAULT"); return .defaultValue(column,nil)
        }
        if take("RENAME") { try require(take("INDEX") || take("KEY"),"unsupported ALTER RENAME operation"); let old = try identifier(); try expect("TO"); return .indexes(.rename(old,try identifier())) }
        if take("PARTITION") { return .partition(.replace(try partitionDefinition())) }
        if take("REMOVE") { try expect("PARTITIONING"); return .partition(.remove) }
        if take("TRUNCATE") { try expect("PARTITION"); return .partition(.truncate(try partitionNames())) }
        if take("REORGANIZE") { try expect("PARTITION"); let names = try partitionNames(); try expect("INTO"); return .partition(.reorganize(names,try partitionItems(method:"",expression:""))) }
        if take("COALESCE") { try expect("PARTITION"); return .partition(.coalesce(try number())) }
        if take("EXCHANGE") { try expect("PARTITION"); let partition = try identifier(); try expect("WITH"); try expect("TABLE"); let table = try name(); if take("WITH") || take("WITHOUT") { try expect("VALIDATION") }; return .partition(.exchange(partition,table)) }
        throw ApplyError("unsupported ALTER TABLE operation",code:.unsupportedAlter)
    }
}

func normalizedDefault(_ value: String?,type: DMLColumnType) throws -> String? {
    guard var value else { return nil }
    if type.base == "json" || type.isSpatial { throw ApplyError("JSON/spatial non-NULL defaults require a parenthesized expression on MySQL 8.0.13 or later") }
    if type.floatingWidth != nil { return try FloatingPointSQL.defaultValue(value,type:type) }
    if type.bitWidth != nil {
        let number: UInt64?
        if value.hasPrefix("b'"), value.hasSuffix("'") {
            let digits=value.dropFirst(2).dropLast()
            number = !digits.isEmpty && digits.allSatisfy({ $0 == "0" || $0 == "1" }) ? UInt64(digits,radix:2) : nil
        } else { number = UInt64(value) }
        guard let number else { throw ApplyError("invalid BIT default") }
        try type.validate(.unsigned(number))
        return "b'"+String(number,radix:2)+"'"
    }
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
