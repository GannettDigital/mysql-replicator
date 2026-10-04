import Foundation
import ReplicatorCodec
import MySQLNIO

struct TableName: Equatable {
    let database: String
    let table: String
    var identity: String {database + "\0" + table}
    var sql: String {get throws {try quoted(database)+"."+quoted(table)}}
}
enum ColumnPlacement: Equatable {case last, first, after(String)}
enum DDLEngine: Equatable {case omitted,defaultEngine,myISAM}
struct CreateDatabase: Equatable {
    let name:String
    let ifNotExists:Bool
    let characterSet:String?
    let collation:String?
}
struct PreparedDatabaseDDL: Codable {
    let name:String
    let before:DDLEncoding?
    let after:DDLEncoding?
    let serverCollation:String?
}
enum DDLStatement: Equatable {
    case createDatabase(CreateDatabase)
    case alterDatabase(CreateDatabase)
    case dropDatabase(String,ifExists:Bool)
    case object(ObjectDDL)
    case alter(TableName,[AlterAction])
    case create(ApplyTable,DDLEngine = .omitted)
    case createIfAbsent(ApplyTable,DDLEngine)
    case createLike(TableName,TableName,ifNotExists:Bool)
    case add(TableName,ApplyColumn,ColumnPlacement)
    case modify(TableName,ApplyColumn,ColumnPlacement?)
    case indexes(TableName,IndexChange)
    case dropColumn(TableName,String)
    case rename(TableName,TableName)
    case renameMany([TableRename])
    case drop(TableName)
    case dropIfPresent(TableName)
    case truncate(TableName)
    var name: TableName? {
        switch self {
        case .createDatabase,.alterDatabase,.dropDatabase,.object,.renameMany: return nil
        case .alter(let t,_): return t
        case .create(let t,_),.createIfAbsent(let t,_): return TableName(database:t.database,table:t.table)
        case .modify(let t,_,_),.indexes(let t,_),.add(let t,_,_),.dropColumn(let t,_),.rename(let t,_),.drop(let t),.dropIfPresent(let t),.createLike(let t,_,_),.truncate(let t): return t
        }
    }
    static func parse(_ query: QueryControl) throws -> DDLStatement {
        try require(query.errorCode == 0,"DDL source query reported an error")
        try DDLPolicy.rejectProhibited(query)
        var parser=try DDLParser(query.sql,database:query.database,sqlMode:query.statusVariables.isEmpty ? 0 : QuerySessionContext(query:query).sqlMode)
        return try parser.parse()
    }
    static func from(_ group: CompleteTransaction) throws -> DDLStatement {
        try require(group.outcome == .statement && group.gtid != nil && !group.anonymous && group.events.count == 2,"DDL requires a standalone named-GTID query group")
        guard case .gtid = group.events[0].control,case .query(let query)=group.events[1].control else {throw ApplyError("invalid DDL event group")}
        return try parse(query)
    }
}
struct PreparedDDL {
    let statement: DDLStatement
    let before: ApplyTable?
    let after: ApplyTable?
    var sql: String
    var database:PreparedDatabaseDDL? = nil
    var additional: [SchemaTransition] = []
    var preservesSchema: Bool {
        switch statement {
        case .createIfAbsent, .createLike(_,_,true): return before != nil && before == after
        case .dropIfPresent: return before == nil && after == nil
        default: return false
        }
    }
}

struct DDLEncoding: Equatable, Codable {let characterSet:String;let collation:String}

extension TargetSession {
    func tableExists(_ name: TableName) throws -> Bool {
        try scalar("SELECT COUNT(*) AS v FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=?",[.init(string:name.database),.init(string:name.table)]) != "0"
    }
    func tableEncoding(_ name:TableName) throws -> DDLEncoding {
        guard let row=try query("SELECT c.CHARACTER_SET_NAME,t.TABLE_COLLATION FROM information_schema.TABLES t JOIN information_schema.COLLATIONS c ON c.COLLATION_NAME=t.TABLE_COLLATION WHERE t.TABLE_SCHEMA=? AND t.TABLE_NAME=?",[.init(string:name.database),.init(string:name.table)]).0.first,
              let charset=row.column("CHARACTER_SET_NAME")?.string,let collation=row.column("TABLE_COLLATION")?.string else {throw ApplyError("missing target table defaults")}
        return DDLEncoding(characterSet:charset,collation:collation)
    }
    func databaseEncoding(_ name:String) throws -> DDLEncoding {
        guard let row=try query("SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?",[.init(string:name)]).0.first,
              let charset=row.column("DEFAULT_CHARACTER_SET_NAME")?.string,let collation=row.column("DEFAULT_COLLATION_NAME")?.string else {throw ApplyError("missing target database defaults")}
        return DDLEncoding(characterSet:charset,collation:collation)
    }
    func resolveEncoding(charset:String?,collation:String?,parent:DDLEncoding?,context:QuerySessionContext) throws -> DDLEncoding {
        if charset==nil && collation==nil {
            guard let parent else {throw ApplyError("missing inherited DDL encoding")}
            return parent
        }
        let rows:[MySQLRow]
        if let collation {
            rows=try query("SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE COLLATION_NAME=?",[.init(string:collation)]).0
        } else if charset=="utf8mb4" {
            rows=try query("SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE ID=?",[.init(string:String(context.defaultUTF8MB4Collation))]).0
            // 5.7 cannot set default_collation_for_utf8mb4. Preserve the SQL;
            // refuse a semantic mismatch instead of inserting a COLLATE rewrite.
            let actual=try scalar("SELECT DEFAULT_COLLATE_NAME AS v FROM information_schema.CHARACTER_SETS WHERE CHARACTER_SET_NAME='utf8mb4'")
            try require(rows.first?.column("COLLATION_NAME")?.string==actual,"source default utf8mb4 collation is unsupported by target: default_collation_for_utf8mb4=\(DDLQueryContextDiagnostic.collation(context.defaultUTF8MB4Collation)), target default=\(actual ?? "unavailable"); no collation substitution")
        } else {
            rows=try query("SELECT CHARACTER_SET_NAME,DEFAULT_COLLATE_NAME AS COLLATION_NAME FROM information_schema.CHARACTER_SETS WHERE CHARACTER_SET_NAME=?",[.init(string:charset!)]).0
        }
        guard let row=rows.first,let found=row.column("CHARACTER_SET_NAME")?.string,let name=row.column("COLLATION_NAME")?.string else {throw ApplyError("unsupported target charset/collation: characterSet=\(charset ?? "inferred"), collation=\(collation ?? "default"); no substitution")}
        try require(charset==nil || charset==found,"DDL charset/collation mismatch: characterSet=\(charset ?? "inferred"), collation=\(name), collation characterSet=\(found)")
        return DDLEncoding(characterSet:found,collation:name)
    }
    func resolveColumn(_ column:ApplyColumn,parent:DDLEncoding,context:QuerySessionContext) throws -> ApplyColumn {
        var result=column
        if try DMLColumnType(column.type).isText {
            let encoding=try resolveEncoding(charset:column.characterSet,collation:column.collation,parent:parent,context:context)
            result.characterSet=encoding.characterSet
            result=ApplyColumn(name:column.name,type:column.type,nullable:column.nullable,collation:encoding.collation,characterSet:encoding.characterSet,defaultValue:column.defaultValue,extra:column.extra,generationExpression:column.generationExpression)
        }
        try result.validate();return result
    }
    func prepareDDL(_ statement: DDLStatement,query source:QueryControl,timestamp:UInt64? = nil) throws -> PreparedDDL {
        let policy = config.compatibilityPolicy
        if policy.collations.isEmpty { return try prepareTargetDDL(statement,query:source,timestamp:timestamp) }
        let context = try QuerySessionContext(query:source)
        var parser = try DDLParser(source.sql,database:source.database,sqlMode:context.sqlMode)
        parser.compatibility = policy; parser.defaultUTF8MB4Collation = context.defaultUTF8MB4Collation
        let translated = try parser.parse()
        var plan = try prepareTargetDDL(translated,query:source,timestamp:timestamp)
        plan.sql = parser.translatedSQL(source.sql)
        return plan
    }
    private func prepareTargetDDL(_ statement: DDLStatement,query source:QueryControl,timestamp:UInt64?) throws -> PreparedDDL {
        try unlock()
        try invalidateStatements()
        try writerExclusion()
        let context=try QuerySessionContext(query:source)
        // Restore expression/literal semantics from the source query context.
        // DDL stays a drained, journaled barrier even for stored objects.
        try require([8,33,45,46,83,192,224,255].contains(context.clientCharset),"unsupported DDL client charset: character_set_client=\(DDLQueryContextDiagnostic.collation(context.clientCharset))")
        if let timestamp { _ = try query("SET SESSION timestamp=\(timestamp).\(String(format:"%06u",context.microseconds))") }
        switch statement {
        case .createDatabase(let definition),.alterDatabase(let definition):
            return try prepareDatabaseDDL(statement,definition:definition,source:source,context:context)
        case .dropDatabase(let name,let conditional):
            return try prepareDropDatabase(statement,name:name,conditional:conditional,source:source,context:context)
        case .renameMany(let renames):
            return try prepareRenames(renames,source:source,context:context)
        case .object(let object):
            return try prepareObjectDDL(statement,object:object,source:source,context:context)
        default: break
        }
        guard let name=statement.name else {throw ApplyError("missing DDL table name")}
        // Read the local LIKE template even when IF NOT EXISTS keeps the
        // destination. MySQL opens the template before testing the destination.
        var template:ApplyTable?
        func checkedSchema(_ name:TableName) throws -> ApplyTable {
            let current=try readSchema(database:name.database,name:name.table)
            if let cached=discovered[name.identity] {try require(current==cached,"target schema drift before DDL")}
            return current
        }
        if case .createLike(_,let source,_)=statement {template=try checkedSchema(source)}
        let exists=try tableExists(name)
        let before:ApplyTable?
        switch statement {
        case .create,.createLike(_,_,false):
            try require(!exists,"DDL CREATE target already exists");before=nil
        case .createIfAbsent,.createLike(_,_,true),.dropIfPresent:
            if exists {before=try checkedSchema(name)}
            else {
                try require(discovered[name.identity]==nil,"target schema disappeared before DDL")
                before=nil
            }
        default: before=try checkedSchema(name)
        }
        var after:ApplyTable?
        var additional: [SchemaTransition] = []
        switch statement {
        case .createDatabase,.alterDatabase,.dropDatabase,.object,.renameMany: throw ApplyError("non-table DDL reached table prediction")
        case .alter(_,let actions):
            after=try altering(before!,actions:actions,context:context)
            for action in actions {
                if case .partition(.exchange(_,let other))=action {
                    try require(actions.count == 1 && other != name,"EXCHANGE must be a standalone table operation")
                    let exchanged=try checkedSchema(other)
                    try require(exchanged.partitions.isEmpty && exchanged.columns == before!.columns && exchanged.primaryKeyColumns == before!.primaryKeyColumns && exchanged.secondaryIndexes == before!.secondaryIndexes && exchanged.defaultCollation == before!.defaultCollation,"EXCHANGE table schema differs")
                    additional.append(SchemaTransition(before:exchanged,after:exchanged))
                }
            }
        case .create(let table,let engine),.createIfAbsent(let table,let engine):
            if let before {after=before;break}
            if engine != .myISAM {
                try require(try scalar("SELECT @@SESSION.default_storage_engine AS v")=="MyISAM","DDL requires target default_storage_engine=MyISAM")
            }
            if engine == .defaultEngine {
                try require(try scalar("SELECT @@SESSION.default_tmp_storage_engine AS v")=="MyISAM","ENGINE='DEFAULT' requires qualified target temporary-engine default")
            }
            let parent=try databaseEncoding(name.database)
            let encoding=try resolveEncoding(charset:table.defaultCharacterSet,collation:table.defaultCollation,parent:parent,context:context)
            after=ApplyTable(database:table.database,table:table.table,columns:try table.columns.map {try resolveColumn($0,parent:encoding,context:context)},primaryKeyColumns:table.primaryKeyColumns,defaultCharacterSet:encoding.characterSet,defaultCollation:encoding.collation,secondaryIndexes:table.secondaryIndexes,partitions:table.partitions)
        case .createLike:
            if let before {after=before}
            else {
                let template=template!
                after=ApplyTable(database:name.database,table:name.table,columns:template.columns,primaryKeyColumns:template.primaryKeyColumns,defaultCharacterSet:template.defaultCharacterSet,defaultCollation:template.defaultCollation,secondaryIndexes:template.secondaryIndexes,partitions:template.partitions)
            }
        case .add(_,let column,let placement):
            let encoding=DDLEncoding(characterSet:before!.defaultCharacterSet!,collation:before!.defaultCollation!)
            let column=try resolveColumn(column,parent:encoding,context:context)
            var columns=before!.columns
            try require(!columns.contains(where:{$0.name==column.name}),"DDL ADD column already exists")
            switch placement {
            case .last: columns.append(column)
            case .first: columns.insert(column,at:0)
            case .after(let key):
                guard let index=columns.firstIndex(where:{$0.name==key}) else {throw ApplyError("DDL AFTER column absent")}
                columns.insert(column,at:index+1)
            }
            after=before!.replacing(columns:columns)
        case .modify(_,let column,let placement):
            let encoding=DDLEncoding(characterSet:before!.defaultCharacterSet!,collation:before!.defaultCollation!)
            let resolved=try resolveColumn(column,parent:encoding,context:context)
            after=try before!.modifying(resolved,placement:placement)
        case .indexes(_,let change):
            after=try change.applying(to:before!)
        case .dropColumn(_,let column):
            after=try altering(before!,actions:[.drop(column)],context:context)
        case .rename(_,let destination):
            try require(!(try tableExists(destination)),"DDL RENAME destination exists")
            after=ApplyTable(database:destination.database,table:destination.table,columns:before!.columns,primaryKeyColumns:before!.primaryKeyColumns,defaultCharacterSet:before!.defaultCharacterSet,defaultCollation:before!.defaultCollation,secondaryIndexes:before!.secondaryIndexes,partitions:before!.partitions)
        case .drop,.dropIfPresent: after=nil
        case .truncate: after=before
        }
        try after?.validate()
        try require(discovered.count - (discovered[name.identity] == nil ? 0 : 1) + (after == nil ? 0 : 1) <= maximumCachedTables,"discovered schema limit reached")
        // The outer preparation layer applies only authorized encoding edits.
        let sql=String(decoding:source.sql,as:UTF8.self)
        try setDDLSession(context,source:source)
        return PreparedDDL(statement:statement,before:before,after:after,sql:sql,additional:additional)
    }
    func prepareDatabaseDDL(_ statement:DDLStatement,definition:CreateDatabase,source:QueryControl,context:QuerySessionContext) throws -> PreparedDDL {
        let exists=try scalar("SELECT COUNT(*) AS v FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?",[.init(string:definition.name)]) != "0"
        let altering: Bool
        if case .alterDatabase=statement {altering=true} else {altering=false}
        try require(altering ? exists : (!exists || definition.ifNotExists),"DDL database existence mismatch")
        let before=exists ? try databaseEncoding(definition.name) : nil
        let after:DDLEncoding?
        var serverCollation:String?
        if altering {after=try resolveEncoding(charset:definition.characterSet,collation:definition.collation,parent:before,context:context)}
        else if let before {after=before}
        else if definition.characterSet==nil && definition.collation==nil {
            guard let row=try query("SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE ID=?",[.init(string:String(config.compatibilityPolicy.targetID(context.serverCollation)))]).0.first,
                  let charset=row.column("CHARACTER_SET_NAME")?.string,let collation=row.column("COLLATION_NAME")?.string else {
                throw ApplyError("unsupported source server collation: collation_server=\(DDLQueryContextDiagnostic.collation(context.serverCollation)), database=\(definition.name); unavailable on target; no substitution")
            }
            after=DDLEncoding(characterSet:charset,collation:collation);serverCollation=collation
        } else {
            after=try resolveEncoding(charset:definition.characterSet,collation:definition.collation,parent:nil,context:context)
        }
        try setDDLSession(context,source:source,useDatabase:false)
        // MySQL write_db_cmd_to_binlog sets Query.db to the created database
        // with suppress_use=true. It is not an instruction to USE a missing DB.
        return PreparedDDL(statement:statement,before:nil,after:nil,sql:String(decoding:source.sql,as:UTF8.self),database:PreparedDatabaseDDL(name:definition.name,before:before,after:after,serverCollation:serverCollation))
    }
    func applyDDL(_ plan: PreparedDDL) throws {
        try unlock()
        try invalidateStatements()
        try writerExclusion()
        if let database=plan.database {
            guard let previous=try scalar("SELECT @@SESSION.collation_server AS v") else {throw ApplyError("missing target server collation")}
            if let collation=database.serverCollation {_ = try query("SET SESSION collation_server=?",[.init(string:collation)])}
            _ = try query(plan.sql,textProtocol:true,timeoutSeconds:config.ddlDeadline,mutation:true)
            if database.serverCollation != nil {_ = try query("SET SESSION collation_server=?",[.init(string:previous)])}
            try resetDMLSession()
            if let after=database.after { try require(try databaseEncoding(database.name)==after,"DDL target database defaults mismatch") }
            else {
                try require(try scalar("SELECT COUNT(*) AS v FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?",[.init(string:database.name)]) == "0","DROP DATABASE left target database present")
                discovered=discovered.filter{$0.value.database != database.name}
            }
            try invalidateStatements()
            return
        }
        if case .object(let object)=plan.statement {
            _ = try query(plan.sql,textProtocol:true,timeoutSeconds:config.ddlDeadline,mutation:true)
            try resetDMLSession()
            try require(try objectExists(object) == (object.operation != .drop),"DDL target object existence mismatch")
            return
        }
        if case .renameMany = plan.statement { try applyRenames(plan); return }
        guard let name=plan.statement.name else {throw ApplyError("missing prepared database DDL")}
        _ = try query(plan.sql,textProtocol:true,timeoutSeconds:config.ddlDeadline,mutation:true)
        try resetDMLSession()
        if let after=plan.after {try require(try readSchema(database:after.database,name:after.table)==after,"DDL target after-schema mismatch")}
        if case .createLike=plan.statement,plan.before==nil {try require(try scalar("SELECT COUNT(*) AS v FROM \(name.sql)")=="0","CREATE LIKE unexpectedly copied rows")}
        if case .truncate=plan.statement {try require(try scalar("SELECT COUNT(*) AS v FROM \(name.sql)")=="0","TRUNCATE did not empty the table")}
        if plan.after?.identity != name.identity {try require(!(try tableExists(name)),"DDL source table remains after rename/drop")}
        for change in plan.additional {
            if let after=change.after {try require(try readSchema(database:after.database,name:after.table)==after,"DDL secondary target schema mismatch");discovered[after.identity]=after}
        }
        discovered.removeValue(forKey:name.identity)
        if let after=plan.after {discovered[after.identity]=after}
        try invalidateStatements()
    }
}
