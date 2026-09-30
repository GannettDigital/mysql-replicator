import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import ReplicatorCodec

final class TargetSession {
    let group: MultiThreadedEventLoopGroup
    let connection: MySQLConnection
    let config: ApplyConfiguration
    init(configuration: ApplyConfiguration,password: String) throws {
        config = configuration
        group = MultiThreadedEventLoopGroup(numberOfThreads:1)
        do {
            let c = configuration.target
            var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .fullVerification
            if let ca = c.caFile { tls.trustRoots = .file(ca) }
            let address = try SocketAddress.makeAddressResolvingHost(c.host,port:c.port)
            connection = try MySQLConnection.connect(to:address,username:c.username,database:"",password:password,tlsConfiguration:tls,serverHostname:c.serverHostname,requireTLS:true,handshakeTimeout:.seconds(10),on:group.next()).wait()
        } catch { try? group.syncShutdownGracefully(); throw error }
    }
    deinit { try? connection.close().wait(); try? group.syncShutdownGracefully() }
    /// Never retry SQL. A timeout closes the socket and leaves the outstanding
    /// intent uncertain. Recovery is a later, separately qualified increment.
    func query(_ sql: String, _ binds: [MySQLData] = [], textProtocol: Bool = false) throws -> ([MySQLRow],UInt64?) {
        let timer = connection.eventLoop.scheduleTask(in:.seconds(10)) { _ = self.connection.close() }
        defer { timer.cancel() }
        var affected: UInt64?
        do {
            let rows = try textProtocol ? connection.simpleQuery(sql).wait() : connection.query(sql,binds,onMetadata:{ affected = $0.affectedRows }).wait()
            return (rows,affected)
        } catch let e as MySQLError {
            switch e {
            case .duplicateEntry: throw ApplyError("target SQL error 1062 (duplicate key)")
            case .invalidSyntax: throw ApplyError("target SQL syntax error")
            case .server(let packet): throw ApplyError("target SQL error \(packet.errorCode), state \(packet.sqlState ?? "unknown")")
            default: throw ApplyError("target connection/protocol failure; SQL outcome may be uncertain")
            }
        } catch { throw ApplyError("target transport failure; SQL outcome may be uncertain") }
    }
    func scalar(_ sql: String, _ binds: [MySQLData] = []) throws -> String? { try query(sql,binds).0.first?.column("v")?.string }
    func nativeExclusion() throws {
        try require(try query("SHOW SLAVE STATUS").0.isEmpty,"target has a native replication channel; stopped-channel adoption is not implemented")
        for table in ["replication_connection_status","replication_applier_status","replication_applier_status_by_worker","replication_applier_status_by_coordinator"] {
            let rows = try query("SELECT SERVICE_STATE FROM performance_schema." + table).0
            try require(rows.allSatisfy { $0.column("SERVICE_STATE")?.string == "OFF" },"native replication worker/receiver is active or indeterminate")
        }
    }
    func preflight() throws {
        let r = try query("SELECT VERSION() AS version,@@server_uuid AS uuid,@@GLOBAL.gtid_mode AS mode,@@GLOBAL.enforce_gtid_consistency AS consistency,@@GLOBAL.log_bin AS log_bin,@@SESSION.sql_log_bin AS session_binlog,@@SESSION.binlog_format AS format,@@SESSION.binlog_row_image AS row_image,@@GLOBAL.binlog_checksum AS checksum").0.first
        try require(r?.column("version")?.string?.hasPrefix("5.7.") == true && r?.column("uuid")?.string?.lowercased() == config.target.targetUUID.lowercased(),"wrong target version/identity")
        try require(r?.column("mode")?.string == "OFF_PERMISSIVE" && r?.column("consistency")?.string == "WARN", "target must use OFF_PERMISSIVE/WARN")
        try require(r?.column("log_bin")?.int == 1 && r?.column("session_binlog")?.int == 1 && r?.column("format")?.string == "ROW" && r?.column("row_image")?.string == "FULL" && r?.column("checksum")?.string == "CRC32","target binary logging differs from contract")
        let ssl = try query("SHOW SESSION STATUS LIKE 'Ssl_cipher'").0
        try require(!(ssl.first?.column("Value")?.string ?? "").isEmpty,"target session has no TLS cipher")
        try nativeExclusion()
        try require(try scalar("SELECT GET_LOCK('mysql-replicator-writer',0) AS v") == "1","target already has a Swift writer")
        try nativeExclusion()
        _ = try query("SET @@SESSION.GTID_NEXT = 'AUTOMATIC'")
        _ = try query("SET SESSION autocommit=1")
        _ = try query("SET NAMES utf8mb4 COLLATE utf8mb4_bin")
        _ = try query("SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES'")

    }
    private(set) var discovered: [String:ApplyTable] = [:]
    func discover(_ event: DecodedEvent) throws -> ApplyTable {
        guard let database = event.database, let name = event.table, let wire = event.wireColumns else {throw ApplyError("missing table-map metadata")}
        let identity = database + "\0" + name
        let table: ApplyTable
        if let cached = discovered[identity] { table = cached }
        else {
            try require(discovered.count < 64,"discovered schema limit reached")
            let binds = [MySQLData(string:database),MySQLData(string:name)]
            let columns = try query("SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION",binds).0
            let keys = try query("SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX",binds).0
            try require(keys.count == 1,"discovered target requires a single primary-key column")
            table = ApplyTable(database:database,table:name,columns:try columns.map { row in
                guard let n = row.column("COLUMN_NAME")?.string, let t = row.column("COLUMN_TYPE")?.string else {throw ApplyError("incomplete target metadata")}
                return ApplyColumn(name:n,type:normalizeType(t),nullable:row.column("IS_NULLABLE")?.string == "YES",collation:row.column("COLLATION_NAME")?.string)
            },primaryKey:keys[0].column("COLUMN_NAME")?.string ?? "")
            try table.validate(); try verifySchema(table)
        }
        try require(wire.count == table.columns.count,"source/target column count differs")
        for (w,c) in zip(wire,table.columns) {
            let type: UInt32 = c.type.hasPrefix("bigint") ? 8 : c.type.hasPrefix("int") ? 3 : 15
            try require(w.type == type && w.interpretation == c.interpretation && w.nullable == c.nullable,"source/target type, signedness, encoding or nullability differs")
            if type == 15 {
                try require(w.maximumBytes == UInt32(c.width! * (c.interpretation == .utf8 ? 4 : 1)),"source/target column width differs")
            }
            if let sourceName = w.name { try require(sourceName == c.name && w.primaryKey == (c.name == table.primaryKey),"source/target column name or primary key differs") }
        }
        discovered[identity] = table
        return table
    }
    private func normalizeType(_ type: String) -> String {
        type.replacingOccurrences(of:#"^(int|bigint)\([0-9]+\)"#,with:"$1",options:.regularExpression)
    }
    func verifySchema(_ t: ApplyTable) throws {
        let binds = [MySQLData(string:t.database),MySQLData(string:t.table)]
        try require(try scalar("SELECT ENGINE AS v FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=?",binds) == "MyISAM","target table is absent or not MyISAM")
        let columns = try query("SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLLATION_NAME,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION",binds).0
        try require(columns.count == t.columns.count,"target schema column count differs")
        for (r,c) in zip(columns,t.columns) {
            try require(r.column("COLUMN_NAME")?.string == c.name && normalizeType(r.column("COLUMN_TYPE")?.string ?? "") == c.type && (r.column("IS_NULLABLE")?.string == "YES") == c.nullable && r.column("COLLATION_NAME")?.string == c.collation && r.column("EXTRA")?.string == "","target schema differs from historical manifest")
        }
        let keys = try query("SELECT INDEX_NAME,COLUMN_NAME,SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY INDEX_NAME,SEQ_IN_INDEX",binds).0
        try require(keys.count == 1 && keys[0].column("INDEX_NAME")?.string == "PRIMARY" && keys[0].column("COLUMN_NAME")?.string == t.primaryKey && keys[0].column("SUB_PART")?.buffer == nil,"initial applier requires only the declared full primary-key index")
        // Without TRIGGER privilege an empty information_schema result can hide
        // triggers. Require visibility explicitly before asserting their absence.
        let grantee = "CONCAT(CHAR(39),REPLACE(CURRENT_USER(),'@',CONCAT(CHAR(39),'@',CHAR(39))),CHAR(39))"
        let grants = try scalar("SELECT (EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER') OR EXISTS(SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER' AND TABLE_SCHEMA=?) OR EXISTS(SELECT 1 FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='TRIGGER' AND TABLE_SCHEMA=? AND TABLE_NAME=?)) AS v",[binds[0],binds[0],binds[1]])
        try require(grants == "1","TRIGGER visibility privilege required for target schema validation")
        try require(try query("SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=? AND EVENT_OBJECT_TABLE=?",binds).0.isEmpty,"target triggers are unsupported")
        try require(try query("SELECT PARTITION_NAME FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND PARTITION_NAME IS NOT NULL",binds).0.isEmpty,"partitioned target tables are unsupported")
    }
    func lock(_ table: ApplyTable) throws {
        try nativeExclusion()
        try require(try scalar("SELECT IS_USED_LOCK('mysql-replicator-writer')=CONNECTION_ID() AS v") == "1","writer ownership lost")
        _ = try query("LOCK TABLES \(table.sqlName) WRITE",textProtocol:true)
        try verifySchema(table)
    }
    func unlock() throws { _ = try query("UNLOCK TABLES",textProtocol:true) }
    func bind(_ value: DecodedValue) throws -> MySQLData {
        switch value {
        case .null: return .null
        case .text(let s): return .init(string:s)
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
    func read(_ t: ApplyTable, key: DecodedValue) throws -> [DecodedValue]? {
        let columns = try t.columns.map { try quoted($0.name) }.joined(separator:",")
        let rows = try query("SELECT \(columns) FROM \(t.sqlName) WHERE \(quoted(t.primaryKey))=?",[try bind(key)]).0
        try require(rows.count <= 1,"primary key did not uniquely identify target row")
        guard let row = rows.first else { return nil }
        return try t.columns.map { c in
            guard let value = row.column(c.name) else { throw ApplyError("missing target column") }
            if value.buffer == nil { return .null }
            switch c.interpretation {
            case .signed: guard let n = value.int64 else { throw ApplyError("invalid target integer") }; return .signed(n)
            case .unsigned: guard let n = value.uint64 else { throw ApplyError("invalid target unsigned integer") }; return .unsigned(n)
            case .utf8: guard let text = value.string else { throw ApplyError("invalid target UTF-8") }; return .text(text)
            case .binary: return .binary(Data(value.buffer!.readableBytesView))
            }
        }
    }
    func apply(_ m: Mutation) throws {
        let t = m.table, row = m.row, keyIndex = t.keyIndex
        let oldKey = (row.before ?? row.after!)[keyIndex]
        let current = try read(t,key:oldKey)
        if row.operation == "insert" { try require(current == nil,"insert primary key already exists") }
        else { try require(exactImage(current,row.before),"target before-image mismatch or missing row") }
        if let before = row.before, let after = row.after, before[keyIndex] != after[keyIndex] {
            try require(try read(t,key:after[keyIndex]) == nil,"updated primary key already exists")
        }
        let names = try t.columns.map { try quoted($0.name) }
        let placeholders = Array(repeating:"?",count:names.count).joined(separator:",")
        let sql: String, values: [DecodedValue]
        switch row.operation {
        case "insert": sql = "INSERT INTO \(try t.sqlName) (\(names.joined(separator:","))) VALUES (\(placeholders))"; values = row.after!
        case "update": sql = "UPDATE \(try t.sqlName) SET \(names.map { $0 + "=?" }.joined(separator:",")) WHERE \(try quoted(t.primaryKey))=?"; values = row.after! + [oldKey]
        case "delete": sql = "DELETE FROM \(try t.sqlName) WHERE \(try quoted(t.primaryKey))=?"; values = [oldKey]
        default: throw ApplyError("unsupported mutation")
        }
        let result = try query(sql,try values.map(bind))
        let expected: UInt64 = row.operation == "update" && exactImage(row.before,row.after) ? 0 : 1
        try require(result.1 == expected,"unexpected target affected-row count")
        if let after = row.after {
            try require(exactImage(try read(t,key:after[keyIndex]),after),"target after-image differs")
            if oldKey != after[keyIndex] { try require(try read(t,key:oldKey) == nil,"old key remains after update") }
        } else { try require(try read(t,key:oldKey) == nil,"deleted row remains") }
    }
}
