import NIOCore
import Logging

public struct MySQLQueryMetadata {
    /// `int<lenenc>`    `affected_rows`    affected rows
    public let affectedRows: UInt64
    
    /// `int<lenenc>`    `last_insert_id`    last insert-id
    public let lastInsertID: UInt64?
}

extension MySQLDatabase {
    public func query(
        _ sql: String,
        _ binds: [MySQLData] = [],
        onMetadata: @escaping (MySQLQueryMetadata) throws -> () = { _ in }
    ) -> EventLoopFuture<[MySQLRow]> {
        nonisolated(unsafe) var rows = [MySQLRow]()
        return self.query(sql, binds, onRow: { row in
            rows.append(row)
        }, onMetadata: onMetadata).map { rows }
    }
    
    public func query(
        _ sql: String,
        _ binds: [MySQLData] = [],
        onRow: @escaping (MySQLRow) throws -> (),
        onMetadata: @escaping (MySQLQueryMetadata) throws -> () = { _ in }
    ) -> EventLoopFuture<Void> {
        let query = MySQLQueryCommand(
            sql: sql,
            binds: binds,
            onRow: onRow,
            onMetadata: onMetadata,
            logger: self.logger
        )
        return self.send(query, logger: self.logger)
    }
}

// Connection-owned and accessed only by commands on its event loop. At capacity,
// new SQL uses the ordinary prepare/execute/close path; it cannot grow unbounded.
final class MySQLPreparedStatementCache: @unchecked Sendable {
    struct Entry { let id: UInt32; let parameters: Int }
    var entries: [String: Entry] = [:]
    let capacity = 128
}

extension MySQLConnection {
    /// Reuse server statements without retrying errors or changing binary values.
    public func cachedQuery(_ sql: String, _ binds: [MySQLData] = [],
                            onMetadata: @escaping (MySQLQueryMetadata) throws -> Void = { _ in }) -> EventLoopFuture<[MySQLRow]> {
        nonisolated(unsafe) var rows: [MySQLRow] = []
        let command = MySQLQueryCommand(sql: sql, binds: binds, onRow: { rows.append($0) },
            onMetadata: onMetadata, logger: logger, cache: preparedStatements)
        return send(command, logger: logger).map { rows }
    }

    /// A barrier: callers must await this before DDL or changing session semantics.
    public func clearPreparedStatementCache() -> EventLoopFuture<Void> {
        let barrier = MySQLStatementCacheBarrier(cache: preparedStatements)
        return send(barrier, logger: logger).flatMap {
            barrier.ids.reduce(self.eventLoop.makeSucceededFuture(())) { future, id in
                future.flatMap { self.send(MySQLCloseStatementCommand(id: id), logger: self.logger) }
            }
        }
    }
}

// Activate only after earlier queued queries have finished publishing entries.
final class MySQLStatementCacheBarrier: MySQLCommand, @unchecked Sendable {
    let cache: MySQLPreparedStatementCache
    var ids: [UInt32] = []
    init(cache: MySQLPreparedStatementCache) { self.cache = cache }
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        ids = cache.entries.values.map { $0.id }
        cache.entries.removeAll()
        return .init(done: true)
    }
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        throw MySQLError.protocolError
    }
}

private final class MySQLCloseStatementCommand: MySQLCommand, @unchecked Sendable {
    let id: UInt32
    init(id: UInt32) { self.id = id }
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        var packet = MySQLPacket()
        MySQLProtocol.COM_STMT_CLOSE(statementID: id).encode(into: &packet)
        return .init(response: [packet], done: true, resetSequence: true)
    }
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        throw MySQLError.protocolError // COM_STMT_CLOSE has no response.
    }
}

final class MySQLQueryCommand: MySQLCommand, @unchecked Sendable { // this is cheating
    let sql: String
    let cache: MySQLPreparedStatementCache?
    var parameterCount = 0
    
    enum State {
        case ready
        case params
        case columns
        case executeColumnCount
        case executeColumns(remaining: Int)
        case rows
        case done
    }

    var state: State
    let binds: [MySQLData]
    let onRow: (MySQLRow) throws -> ()
    let onMetadata: (MySQLQueryMetadata) throws -> ()
    let logger: Logger

    private var prepareColumns: [MySQLProtocol.ColumnDefinition41]
    private var executeColumns: [MySQLProtocol.ColumnDefinition41]
    private var params: [MySQLProtocol.ColumnDefinition41]
    private var ok: MySQLProtocol.COM_STMT_PREPARE_OK?

    private var lastUserError: (any Error)?
    var statementID: UInt32?
    
    init(
        sql: String,
        binds: [MySQLData],
        onRow: @escaping (MySQLRow) throws -> (),
        onMetadata: @escaping (MySQLQueryMetadata) throws -> (),
        logger: Logger,
        cache: MySQLPreparedStatementCache? = nil
    ) {
        self.cache = cache
        self.state = .ready
        self.sql = sql
        self.binds = binds
        self.prepareColumns = []
        self.executeColumns = []
        self.params = []
        self.onRow = onRow
        self.onMetadata = onMetadata
        self.logger = logger
    }
    
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        self.logger.trace("MySQLQueryCommand.\(self.state)")
        guard !packet.isError else {
            self.state = .done
            self.cache?.entries.removeValue(forKey: self.sql)

            let errorPacket = try packet.decode(
                MySQLProtocol.ERR_Packet.self,
                capabilities: capabilities
            )
            let error: any Error
            switch errorPacket.errorCode {
            case .DUP_ENTRY:
                error = MySQLError.duplicateEntry(errorPacket.errorMessage)
            case .PARSE_ERROR:
                error = MySQLError.invalidSyntax(errorPacket.errorMessage)
            default:
                error = MySQLError.server(errorPacket)
            }

            var response: [MySQLPacket] = []
            if let statementID = self.statementID {
                self.statementID = nil
                var packet = MySQLPacket()
                MySQLProtocol.COM_STMT_CLOSE(
                    statementID: statementID
                ).encode(into: &packet)
                response = [packet]
            }

            return .init(
                response: response,
                done: true,
                resetSequence: true,
                error: error
            )
        }
        switch self.state {
        case .ready:
            let res = try packet.decode(MySQLProtocol.COM_STMT_PREPARE_OK.self, capabilities: capabilities)
            self.ok = res
            self.parameterCount = Int(res.numParams)
            if res.numParams != 0 {
                self.state = .params
            } else if res.numColumns != 0 {
                self.state = .columns
            } else {
                self.state = .executeColumnCount
            }
            self.statementID = res.statementID
            let execute = MySQLProtocol.COM_STMT_EXECUTE(
                statementID: res.statementID,
                flags: [],
                values: self.binds
            )
            return try .init(response: [.encode(execute, capabilities: capabilities)], resetSequence: true)
        case .params:
            let param = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            self.params.append(param)
            if self.params.count == numericCast(self.ok!.numParams) {
                if self.ok!.numColumns != 0 {
                    self.state = .columns
                } else {
                    self.state = .rows
                }
            }
            return .noResponse
        case .columns:
            let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            self.prepareColumns.append(column)
            if self.prepareColumns.count == numericCast(self.ok!.numColumns) {
                self.state = .executeColumnCount
            }
            return .noResponse
        case .executeColumnCount:
            guard !packet.isOK else {
                return try self.done(packet: &packet, capabilities: capabilities)
            }
            guard let count = packet.payload.readLengthEncodedInteger() else {
                throw MySQLError.protocolError
            }
            self.state = .executeColumns(remaining: numericCast(count))
            return .noResponse
        case .executeColumns(var remaining):
            let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            self.executeColumns.append(column)
            remaining -= 1
            switch remaining {
            case 0:
                self.state = .rows
            default:
                self.state = .executeColumns(remaining: remaining)
            }
            return .noResponse
        case .rows:
            if packet.isEOF || packet.isOK && executeColumns.count == 0 {
                return try self.done(packet: &packet, capabilities: capabilities)
            }

            let data = try MySQLProtocol.BinaryResultSetRow.decode(from: &packet, columns: executeColumns)
            let row = MySQLRow(
                format: .binary,
                columnDefinitions: self.executeColumns,
                values: data.values
            )
            do {
                try self.onRow(row)
            } catch {
                self.lastUserError = error
            }
            return .noResponse
        case .done: fatalError()
        }
    }

    func done(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        self.state = .done
        if packet.isOK {
            let ok = try MySQLProtocol.OK_Packet.decode(from: &packet, capabilities: capabilities)
            do {
                try self.onMetadata(.init(affectedRows: ok.affectedRows, lastInsertID: ok.lastInsertID))
            } catch {
                self.lastUserError = error
            }
        }
        if let cache, lastUserError == nil,
           cache.entries[sql] != nil || cache.entries.count < cache.capacity {
            cache.entries[sql] = .init(id: statementID!, parameters: parameterCount)
            statementID = nil // ownership transferred to the connection
            return .init(response: [], done: true, resetSequence: true)
        }
        cache?.entries.removeValue(forKey: sql)
        var packet = MySQLPacket()
        MySQLProtocol.COM_STMT_CLOSE(
            statementID: self.statementID!
        ).encode(into: &packet)
        self.statementID = nil
        return .init(
            response: [packet],
            done: true,
            resetSequence: true,
            error: self.lastUserError
        )
    }
    
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if let entry = cache?.entries[sql] {
            guard entry.parameters == binds.count else { throw MySQLError.protocolError }
            statementID = entry.id
            parameterCount = entry.parameters
            state = .executeColumnCount
            return try .response([.encode(MySQLProtocol.COM_STMT_EXECUTE(
                statementID: entry.id, flags: [], values: binds), capabilities: capabilities)])
        }
        let prepare = MySQLProtocol.COM_STMT_PREPARE(query: self.sql)
        return try .response([.encode(prepare, capabilities: capabilities)])
    }

}
