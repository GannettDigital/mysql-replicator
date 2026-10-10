import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import ReplicatorCodec

final class TargetSession {
    let group: MultiThreadedEventLoopGroup
    let connection: MySQLConnection
    let timings: StageTimings
    var statementTrace = TargetStatementTrace()
    var lockEpoch = TableLockEpoch()
    var contract: TargetContract { config.replicationProfile.targetContract }
    let config: ApplyConfiguration
    init(configuration: ApplyConfiguration,password: String, timings: StageTimings = .init()) throws {
        self.timings = timings
        config = configuration
        group = MultiThreadedEventLoopGroup(numberOfThreads:1)
        do {
            let c = configuration.target
            try c.validate()
            let address = try c.unixSocket.map { try SocketAddress(unixDomainSocketPath:$0) }
                ?? SocketAddress.makeAddressResolvingHost(c.host!,port:c.port!)
            let loop=group.next()
            connection = try timings.measure("target.connect") { try MySQLConnection.connect(to:address,username:c.username,database:"",password:password,tlsConfiguration:c.tlsConfiguration(),serverHostname:c.serverHostname,requireTLS:c.requireTLS,handshakeTimeout:.seconds(10),on:loop).wait() }
        } catch {
            try? group.syncShutdownGracefully()
            let missingSocket = configuration.target.unixSocket != nil && (error as? IOError)?.errnoCode == ENOENT
            if isTargetTransportFailure(error) || missingSocket { throw TargetConnectionFailure(description:"target connection unavailable") }
            throw error
        }
    }
    deinit { try? connection.close().wait(); try? group.syncShutdownGracefully() }
    func profile<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        if config.applierProfiling != true { return try body() }
        return try timings.measure("apply.detail." + stage,body)
    }
    func checkConnection() throws {
        if connection.isClosed { throw TargetConnectionFailure(description:"target connection closed") }
    }
    /// Never retry SQL. A timeout closes the socket and leaves the outstanding
    /// intent uncertain. Recovery is a later, separately qualified increment.
    func query(_ sql: String, _ binds: [MySQLData] = [], textProtocol: Bool = false, timeoutSeconds: Int = 10, mutation: Bool = false) throws -> ([MySQLRow],UInt64?) {
        try checkConnection()
        let timer = connection.eventLoop.scheduleTask(in:.seconds(Int64(timeoutSeconds))) { _ = self.connection.close() }
        defer { timer.cancel() }
        var affected: UInt64?
        if mutation { statementTrace = TargetStatementTrace(phase:.possiblyExecuted,sql:sql) }
        do {
            let rows = try timings.measure("target.sql") {
                try profile(textProtocol ? "sql.text" : "sql.prepared") {
                    try textProtocol ? connection.simpleQuery(sql).wait() : connection.cachedQuery(sql,binds,onMetadata:{ affected = $0.affectedRows }).wait()
                }
            }
            if mutation { statementTrace.phase = .acknowledged }
            return (rows,affected)
        } catch let e where isTargetTransportFailure(e) {
            throw TargetConnectionFailure(description:"target connection interrupted")
        } catch let e as MySQLError {
            switch e {
            case .duplicateEntry: throw ApplyError("target SQL error 1062 (duplicate key)",code:.duplicateKey,mysqlErrorNumber:1062,sqlState:"23000")
            case .invalidSyntax: throw ApplyError("target SQL syntax error")
            case .server(let packet): throw ApplyError("target SQL error \(packet.errorCode), state \(packet.sqlState ?? "unknown")",code:packet.errorCode == 1062 ? .duplicateKey : .targetSQL,mysqlErrorNumber:Int(packet.errorCode.rawValue),sqlState:packet.sqlState)
            default: throw ApplyError("target connection/protocol failure; SQL outcome may be uncertain")
            }
        } catch { throw ApplyError("target transport failure; SQL outcome may be uncertain") }
    }
    func scalar(_ sql: String, _ binds: [MySQLData] = []) throws -> String? { try query(sql,binds).0.first?.column("v")?.string }
    func nativeExclusion() throws {
        try require(try query(contract.statusSQL).0.isEmpty,"target has a native replication channel; stopped-channel adoption is not implemented")
        let sql = ["replication_connection_status","replication_applier_status","replication_applier_status_by_worker","replication_applier_status_by_coordinator"]
            .map { "SELECT SERVICE_STATE FROM performance_schema." + $0 }.joined(separator:" UNION ALL ")
        let rows = try query(sql).0
        try require(rows.allSatisfy { $0.column("SERVICE_STATE")?.string == "OFF" },"native replication worker/receiver is active or indeterminate")
    }

    private(set) var targetUUID: String?
    func preflight() throws {
        let r = try query("SELECT VERSION() AS version,@@server_uuid AS uuid,@@GLOBAL.gtid_mode AS mode,@@GLOBAL.enforce_gtid_consistency AS consistency,@@GLOBAL.log_bin AS log_bin,@@SESSION.sql_log_bin AS session_binlog,@@SESSION.binlog_format AS format,@@SESSION.binlog_row_image AS row_image,@@GLOBAL.binlog_checksum AS checksum").0.first
        try require(r?.column("version")?.string?.hasPrefix(contract.versionPrefix) == true,"wrong target version for replication profile")
        guard let uuid=r?.column("uuid")?.string?.lowercased(),UUID(uuidString:uuid) != nil else {throw ApplyError("invalid discovered target UUID")}
        try require(uuid != config.source.sourceUUID.lowercased(),"source and target UUID must differ")
        targetUUID=uuid
        try require(r?.column("mode")?.string == contract.gtidMode && r?.column("consistency")?.string == contract.gtidConsistency, "target GTID settings differ from replication profile")
        try require(r?.column("log_bin")?.int == 1 && r?.column("session_binlog")?.int == 1 && r?.column("format")?.string == "ROW" && r?.column("row_image")?.string == "FULL" && r?.column("checksum")?.string == "CRC32","target binary logging differs from contract")
        let ssl = try query("SHOW SESSION STATUS LIKE 'Ssl_cipher'").0
        let encrypted = !(ssl.first?.column("Value")?.string ?? "").isEmpty
        try require(encrypted == config.target.requireTLS,"target session TLS differs from configured transport")
        guard let packet = Int(try scalar("SELECT @@max_allowed_packet AS v") ?? ""), packet >= 4096 else { throw ApplyError("invalid target packet limit") }
        insertByteLimit = min(config.batchPolicy.maximumInsertBytes,packet/2)
        try nativeExclusion()
        let ownership=try scalar("SELECT GET_LOCK('mysql-replicator-writer',0) AS v")
        if ownership == "0" { throw TargetConnectionFailure(description:"waiting for target writer ownership") }
        try require(ownership == "1","target writer ownership is indeterminate")
        try nativeExclusion()
        try contract.configure(self)
        _ = try query("SET SESSION autocommit=1")
        _ = try query("SET SESSION time_zone='+00:00'")
        _ = try query("SET NAMES utf8mb4 COLLATE utf8mb4_bin")
        _ = try query("SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES'")

    }
    func resetDMLSession() throws {
        _ = try query("SET SESSION timestamp=DEFAULT")
        _ = try query("SET SESSION time_zone='+00:00'")
        _ = try query("SET NAMES utf8mb4 COLLATE utf8mb4_bin")
        _ = try query("SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES'")
    }
    private(set) var insertByteLimit = 1024*1024
    var discovered: [String:ApplyTable] = [:]
    // Dedicated replica: target-local schema/grant/channel changes during a run
    // are outside the contract. Keep validated plans across bounded lock epochs.
    // A new connection starts empty; ordered DDL clears these before and after.
    private var validatedPlans: [String:DMLSQLPlan] = [:]
    func discover(_ event: DecodedEvent) throws -> ApplyTable {
        try profile("target.discover") {
            guard let database = event.database, let name = event.table, event.wireColumns != nil else {throw ApplyError("missing table-map metadata")}
            let identity = database + "\0" + name
            let table: ApplyTable
            if let cached = discovered[identity] { table = cached }
            else {
                try require(discovered.count < maximumCachedTables,"discovered schema limit reached")
                // Discovery is a drained barrier. Release any prior table lock
                // before querying metadata for a previously unseen table.
                try unlock()
                table=try readSchema(database:database,name:name)
            }
            try Self.validateTableMap(event, table:table,compatibility:config.compatibilityPolicy,legacyMetadata:config.replicationProfile.sourceContract.requiresHistoricalSchema)
            discovered[identity] = table
            return table
        }
    }
    /// Pure source/target compatibility validation; safe with an immutable table
    /// snapshot while the target connection executes an earlier batch.
    static func validateTableMap(_ event: DecodedEvent, table: ApplyTable,compatibility: CompatibilityPolicy = .init(), legacyMetadata: Bool = false) throws {
        guard let wire = event.wireColumns else { throw ApplyError("missing table-map metadata") }
        try DMLTablePlan(table,compatibility:compatibility).validate(wire:wire,legacyMetadata:legacyMetadata)
    }

    func readSchema(database: String,name: String) throws -> ApplyTable {
        try profile("target.read_schema") {
            let binds = [MySQLData(string:database),MySQLData(string:name)]
            let columns = try query("SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,CHARACTER_SET_NAME,COLLATION_NAME,COLUMN_DEFAULT,EXTRA,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION",binds).0
            let keys = try query("SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX",binds).0
            try require((1...16).contains(keys.count),"discovered target requires a primary key with 1 to 16 columns")
            var table = ApplyTable(database:database,table:name,columns:try columns.map { row in
                guard let n = row.column("COLUMN_NAME")?.string, let t = row.column("COLUMN_TYPE")?.string else {throw ApplyError("incomplete target metadata")}
                var column=ApplyColumn(name:n,type:normalizeType(t),nullable:row.column("IS_NULLABLE")?.string == "YES",collation:row.column("COLLATION_NAME")?.string)
                column.characterSet=row.column("CHARACTER_SET_NAME")?.string
                column.defaultValue=try contract.columnDefault(row.column("COLUMN_DEFAULT")?.string,type:t)
                column.extra=contract.columnExtra(row.column("EXTRA")?.string,defaultValue:row.column("COLUMN_DEFAULT")?.string,type:t)
                column.generationExpression=try row.column("GENERATION_EXPRESSION")?.string.flatMap { $0.isEmpty ? nil : try DDLExpression.canonical($0) }
                return column
            },primaryKeyColumns:keys.map { $0.column("COLUMN_NAME")?.string ?? "" })
            let encoding=try tableEncoding(TableName(database:database,table:name))
            table.defaultCharacterSet=encoding.characterSet;table.defaultCollation=encoding.collation
            table.secondaryIndexes=try readIndexes(database:database,name:name,primaryKey:table.primaryKeyColumns)
            table.partitions=try readPartitions(database:database,name:name)
            try table.validate(); try verifySchema(table)
            return table
        }
    }
    private func normalizeType(_ type: String) -> String {
        type.replacingOccurrences(of:#"^(tinyint|smallint|mediumint|int|bigint|year)\([0-9]+\)"#,with:"$1",options:.regularExpression)
    }
    func readIndexes(database:String,name:String,primaryKey:[String]) throws -> [ApplyIndex] {
        let rows=try query("SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,SUB_PART,INDEX_TYPE,COLLATION FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY INDEX_NAME,SEQ_IN_INDEX",[.init(string:database),.init(string:name)]).0
        var indexes:[ApplyIndex]=[], primary=0
        for row in rows {
            guard let name=row.column("INDEX_NAME")?.string, let column=row.column("COLUMN_NAME")?.string,
                  let unique=row.column("NON_UNIQUE")?.int, [0,1].contains(unique), let ordinal=row.column("SEQ_IN_INDEX")?.int,
                  let type=row.column("INDEX_TYPE")?.string,let direction=row.column("COLLATION")?.string else {throw ApplyError("incomplete index metadata")}
            let prefix=row.column("SUB_PART")?.int
            if name == "PRIMARY" {
                primary += 1
                try require(primary <= primaryKey.count && column == primaryKey[primary-1] && ordinal == primary && unique == 0 && prefix == nil && type == "BTREE" && direction == "A","unsupported primary-key index")
            } else {
                let part=ApplyIndexPart(column:column,prefix:prefix,direction:direction)
                if let previous=indexes.last, previous.name == name {
                    try require(ordinal == previous.parts.count+1 && previous.unique == (unique == 0) && previous.type == type,"inconsistent index metadata")
                    indexes[indexes.count-1]=ApplyIndex(name:name,unique:previous.unique,parts:previous.parts+[part],type:type)
                } else {
                    try require(ordinal == 1 && indexes.count < 63,"invalid index ordinal/count")
                    indexes.append(ApplyIndex(name:name,unique:unique == 0,parts:[part],type:type))
                }
            }
        }
        try require(primary == primaryKey.count,"missing primary-key index")
        return indexes.sorted{$0.name.lowercased() < $1.name.lowercased()}
    }
    func verifySchema(_ t: ApplyTable) throws {
        validatedPlans.removeValue(forKey:t.identity)
        try timings.measure("target.schema") { try verifyTargetSchema(t) }
        try require(validatedPlans.count < maximumCachedTables,"validated schema limit reached")
        validatedPlans[t.identity] = try DMLSQLPlan(t)
    }
    private func verifyTargetSchema(_ t: ApplyTable) throws {
        let binds = [MySQLData(string:t.database),MySQLData(string:t.table)]
        let metadata = try query("SELECT ENGINE,TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=?",binds).0.first
        try require(metadata?.column("ENGINE")?.string == contract.engine,"target table is absent or not \(contract.engine)")
        try contract.validateTable(t,target:self)
        // A collation uniquely determines its charset; discovery/DDL resolution
        // already validates that mapping when constructing the ApplyTable.
        try require(metadata?.column("TABLE_COLLATION")?.string == t.defaultCollation,"target table defaults differ from historical schema")
        let columns = try query("SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,CHARACTER_SET_NAME,COLLATION_NAME,EXTRA,COLUMN_DEFAULT,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION",binds).0
        try require(columns.count == t.columns.count,"target schema column count differs")
        for (r,c) in zip(columns,t.columns) {
            try require(r.column("COLUMN_NAME")?.string == c.name && normalizeType(r.column("COLUMN_TYPE")?.string ?? "") == c.type && (r.column("IS_NULLABLE")?.string == "YES") == c.nullable && r.column("COLLATION_NAME")?.string == c.collation && r.column("CHARACTER_SET_NAME")?.string == c.characterSet && contract.columnExtra(r.column("EXTRA")?.string,defaultValue:r.column("COLUMN_DEFAULT")?.string,type:c.type) == c.extra && (try contract.columnDefault(r.column("COLUMN_DEFAULT")?.string,type:c.type)) == c.defaultValue && (try r.column("GENERATION_EXPRESSION")?.string.flatMap { $0.isEmpty ? nil : try DDLExpression.canonical($0) }) == c.generationExpression,"target schema differs from historical manifest")
        }
        try require(try readIndexes(database:t.database,name:t.table,primaryKey:t.primaryKeyColumns) == t.secondaryIndexes,"target indexes differ from historical schema")
        try verifyTriggerVisibility(t)
        try require(try query("SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=? AND EVENT_OBJECT_TABLE=?",binds).0.isEmpty,"target triggers are unsupported")
        try require(try readPartitions(database:t.database,name:t.table) == t.partitions,"target partition layout differs from historical schema")
    }
    private func verifyTriggerVisibility(_ t: ApplyTable) throws {
        let binds = [MySQLData(string:t.database),MySQLData(string:t.table)]
        // Without TRIGGER privilege an empty information_schema result can hide
        // triggers. Require visibility explicitly before asserting their absence.
        let grantee = "CONCAT(CHAR(39),REPLACE(CURRENT_USER(),'@',CONCAT(CHAR(39),'@',CHAR(39))),CHAR(39))"
        let grants = try scalar("SELECT (EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER') OR EXISTS(SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER' AND TABLE_SCHEMA=?) OR EXISTS(SELECT 1 FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER' AND TABLE_SCHEMA=? AND TABLE_NAME=?)) AS v",[binds[0],binds[0],binds[1]])
        try require(grants == "1","TRIGGER visibility privilege required for target schema validation")
    }
    func invalidateStatements() throws {
        validatedPlans.removeAll(keepingCapacity:true)
        try timings.measure("target.statement_invalidation") { try connection.clearPreparedStatementCache().wait() }
    }
    func writerExclusion() throws {
        try nativeExclusion()
        try require(try scalar("SELECT IS_USED_LOCK('mysql-replicator-writer')=CONNECTION_ID() AS v") == "1","writer ownership lost")
    }
    func prepareDML(_ group: PreparedDMLGroup) throws {
        // DDL clears plans for every table. An InnoDB group can revisit several
        // already-discovered tables; restore their plans before BEGIN, without
        // LOCK TABLES (which would implicitly commit the transaction).
        var seen = Set<String>()
        for mutation in group.mutations where seen.insert(mutation.table.identity).inserted {
            let table = mutation.table
            if validatedPlans[table.identity]?.table != table { try verifySchema(table) }
        }
    }
    func lock(_ table: ApplyTable) throws {
        // GET_LOCK belongs to this connection until explicit release or session
        // death. Reconnect creates a new session and must acquire ownership again.
        if !config.target.explicitTableLocks {
            if validatedPlans[table.identity]?.table != table { try verifySchema(table) }
            return
        }
        if lockEpoch.canReuse(table, at:ProcessInfo.processInfo.systemUptime) { return }
        try unlock()
        _ = try timings.measure("target.lock") { try query("LOCK TABLES \(table.sqlName) WRITE",textProtocol:true) }
        lockEpoch.acquired(table, at:ProcessInfo.processInfo.systemUptime)
        do {
            if validatedPlans[table.identity]?.table != table { try verifySchema(table) }
        }
        catch { try? unlock(); throw error }
    }
    func releaseExpiredLock() throws {
        guard config.target.explicitTableLocks else { return }
        if lockEpoch.expired(at:ProcessInfo.processInfo.systemUptime) { try unlock() }
    }
    func completedDMLGroup() throws {
        guard config.target.explicitTableLocks else { return }
        lockEpoch.completedGroup()
        try releaseExpiredLock()
    }
    func unlock() throws {
        guard lockEpoch.table != nil else { return }
        _ = try timings.measure("target.unlock") { try query("UNLOCK TABLES",textProtocol:true) }
        lockEpoch.released()
    }
    func bind(_ value: DecodedValue) throws -> MySQLData {
        switch value {
        case .null: return .null
        case .text(let s), .decimal(let s), .temporal(let s): return .init(string:s)
        case .binary(let data): return .init(type:.blob,buffer:ByteBuffer(bytes:data))
        case .signed(let n):
            var b = ByteBufferAllocator().buffer(capacity:8); b.writeInteger(n,endianness:.little)
            return .init(type:.longlong,buffer:b)
        case .unsigned(let n):
            var b = ByteBufferAllocator().buffer(capacity:8); b.writeInteger(n,endianness:.little)
            return .init(type:.longlong,buffer:b,isUnsigned:true)
        case .absent: throw ApplyError("absent full row value")
        }
    }
    func read(_ t: ApplyTable, key: [DecodedValue]) throws -> [DecodedValue]? {
        try timings.measure("target.read") { try readRow(t,key:key) }
    }
    private func readRow(_ t: ApplyTable, key: [DecodedValue]) throws -> [DecodedValue]? {
        let plan = try sqlPlan(t)
        let rows = try query(plan.select,try key.map(bind)).0
        try require(rows.count <= 1,"primary key did not uniquely identify target row")
        guard let row = rows.first else { return nil }
        return try profile("target.decode_result") {
            try t.columns.enumerated().map { index,c in
                let type = plan.columnTypes[index]
                guard let value = row.column(c.name) else { throw ApplyError("missing target column") }
                if value.buffer == nil { return .null }
                switch type.interpretation {
                case .signed: guard let n = value.int64 else { throw ApplyError("invalid target integer") }; return .signed(n)
                case .unsigned: guard let n = value.uint64 else { throw ApplyError("invalid target unsigned integer") }; return .unsigned(n)
                case .utf8: guard let text = value.string else { throw ApplyError("invalid target UTF-8") }; return .text(text)
                case .binary: return .binary(Data(value.buffer!.readableBytesView))
                case .decimal:
                    guard let s=value.string else {throw ApplyError("invalid target decimal")}; let result=DecodedValue.decimal(s); try type.validate(result); return result
                case .temporal:
                    guard let s=value.string else {throw ApplyError("invalid target temporal value")}; return .temporal(try type.canonicalTemporal(s))
                }
            }
        }
    }
    func apply(_ m: Mutation) throws {
        try timings.measure("target.row") { try applyRow(m) }
    }
    private func applyRow(_ m: Mutation) throws {
        let t = m.table, row = m.row, plan = try sqlPlan(t)
        let oldImage = row.before ?? row.after!
        let oldKey = plan.keyIndexes.map { oldImage[$0] }
        // Plain INSERT enforces primary and secondary unique keys atomically.
        // No IGNORE/REPLACE/upsert: duplicate keys still block the pending group.
        if row.operation != "insert" {
            try require(exactImage(try read(t,key:oldKey),row.before),"target before-image mismatch or missing row")
        }
        if let before = row.before, let after = row.after {
            let newKey = plan.keyIndexes.map { after[$0] }
            if !exactImage(oldKey,newKey), let existing = try read(t,key:newKey) {
                // A case/padding-equivalent text key may resolve to the same row.
                try require(exactImage(existing,before),"updated primary key already exists")
            }
        }
        let sql: String, values: [DecodedValue]
        switch row.operation {
        case "insert": sql = plan.insert; values = plan.generatedIndexes.isEmpty ? row.after! : plan.writeIndexes.map { row.after![$0] }
        case "update": sql = plan.update; values = (plan.generatedIndexes.isEmpty ? row.after! : plan.writeIndexes.map { row.after![$0] }) + oldKey
        case "delete": sql = plan.delete; values = oldKey
        default: throw ApplyError("unsupported mutation")
        }
        let binds = try profile("target.bind") { try values.map(bind) }
        let result = try query(sql,binds,mutation:true)
        let expected: UInt64 = row.operation == "update" && exactImage(row.before,row.after) ? 0 : 1
        try require(result.1 == expected,"unexpected target affected-row count")
        if let after=row.after { try verifyGeneratedValues(t,after:after,plan:plan) }
        // A successful statement with the expected affected-row count is the
        // completion signal. Pre-write images, strict SQL mode and schema checks
        // remain enforced; independent qualification compares resulting values.
    }
    func applyInserts(_ mutations: [Mutation]) throws {
        try timings.measure("target.insert_chunk") {
            guard let first = mutations.first else { throw ApplyError("empty INSERT chunk") }
            try require(mutations.count <= config.batchPolicy.maximumInsertRows && mutations.allSatisfy {
                $0.table == first.table && $0.row.operation == "insert" && $0.row.before == nil && $0.row.after?.count == first.table.columns.count
            }, "incompatible INSERT chunk")
            try require(mutations.reduce(0) { $0+DMLExecution.insertBytes($1) } <= insertByteLimit,"INSERT chunk exceeds packet budget")
            let plan = try sqlPlan(first.table)
            let binds = try profile("target.bind") { try mutations.flatMap { mutation in try plan.writeIndexes.map { try bind(mutation.row.after![$0]) } } }
            let result = try query(plan.insertSQL(rows:mutations.count),binds,mutation:true)
            try require(result.1 == UInt64(mutations.count),"unexpected multi-row INSERT affected-row count")
            if !plan.generatedIndexes.isEmpty {
                for mutation in mutations { try verifyGeneratedValues(first.table,after:mutation.row.after!,plan:plan) }
            }
        }
    }
    /// Generated values are computed by the target, not bound by us. Compare
    /// those fields to the FULL source image before completing the intent. This
    /// also catches mismatched expressions in an externally prepared snapshot;
    /// TABLE_MAP contains types but does not describe generated expressions.
    private func verifyGeneratedValues(_ table: ApplyTable,after: [DecodedValue],plan: DMLSQLPlan) throws {
        let generated=plan.generatedIndexes
        guard !generated.isEmpty else { return }
        try profile("target.generated_check") {
            guard let actual=try read(table,key:plan.keyIndexes.map{after[$0]}) else {throw ApplyError("generated-column result row is missing")}
            try require(exactImage(generated.map{actual[$0]},generated.map{after[$0]}),"target generated-column values differ from source image")
        }
    }
    private func sqlPlan(_ table: ApplyTable) throws -> DMLSQLPlan {
        try profile("target.sql_plan") {
            guard let plan = validatedPlans[table.identity], plan.table == table else {
                throw ApplyError("missing validated target SQL plan")
            }
            return plan
        }
    }
}
