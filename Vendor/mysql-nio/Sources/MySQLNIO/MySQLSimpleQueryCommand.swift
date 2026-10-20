import NIOCore

extension MySQLDatabase {
    public func simpleQuery(_ sql: String) -> EventLoopFuture<[MySQLRow]> {
        nonisolated(unsafe) var rows = [MySQLRow]()
        return self.simpleQuery(sql) { row in
            rows.append(row)
        }.map { rows }
    }
    
    /// Execute SQL in its logged client encoding without a UTF-8 round trip.
    public func simpleQueryBytes(_ sql: [UInt8]) -> EventLoopFuture<[MySQLRow]> {
        nonisolated(unsafe) var rows = [MySQLRow]()
        let query = MySQLSimpleQueryCommand(sqlBytes: sql, onRow: { rows.append($0) })
        return self.send(query, logger: self.logger).map { rows }
    }

    public func simpleQuery(_ sql: String, onRow: @escaping (MySQLRow) -> ()) -> EventLoopFuture<Void> {
        let query = MySQLSimpleQueryCommand(sql: sql, onRow: onRow)
        return self.send(query, logger: self.logger)
    }
}

final class MySQLSimpleQueryCommand: MySQLCommand, @unchecked Sendable { // this is cheating
    let sqlBytes: [UInt8]
    
    enum State {
        case ready
        case columns(count: UInt64)
        case rows
        case done
    }
    var state: State
    
    var columns: [MySQLProtocol.ColumnDefinition41]
    let onRow: (MySQLRow) -> ()
    
    convenience init(sql: String, onRow: @escaping (MySQLRow) -> ()) {
        self.init(sqlBytes: Array(sql.utf8), onRow: onRow)
    }

    init(sqlBytes: [UInt8], onRow: @escaping (MySQLRow) -> ()) {
        self.state = .ready
        self.sqlBytes = sqlBytes
        self.columns = []
        self.onRow = onRow
    }
    
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        // print("QUERY \(state): \(packet.payload.debugDescription)")
        guard !packet.isError else {
            self.state = .done
            let errorPacket = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            let error: any Error
            switch errorPacket.errorCode {
            case .DUP_ENTRY:
                error = MySQLError.duplicateEntry(errorPacket.errorMessage)
            case .PARSE_ERROR:
                error = MySQLError.invalidSyntax(errorPacket.errorMessage)
            default:
                error = MySQLError.server(errorPacket)
            }
            throw error
        }
        switch self.state {
        case .ready:
            if packet.isOK {
                self.state = .done
                return .done
            } else {
                let res = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
                self.state = .columns(count: res.columnCount)
                return .noResponse
            }
        case .columns(let total):
            let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            self.columns.append(column)
            if self.columns.count == numericCast(total) {
                self.state = .rows
            }
            return .noResponse
        case .rows:
            guard !packet.isEOF else {
                self.state = .done
                return .done
            }
            
            let data = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
            let row = MySQLRow(
                format: .text,
                columnDefinitions: self.columns,
                values: data.values
            )
            self.onRow(row)
            return .noResponse
        case .done: throw MySQLError.protocolError
        }
    }
    
    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        try .response([
            .encode(MySQLRawQuery(bytes: self.sqlBytes), capabilities: capabilities)
        ])
    }
}

private struct MySQLRawQuery: MySQLPacketEncodable {
    let bytes: [UInt8]
    func encode(to packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws {
        packet.payload.writeInteger(UInt8(0x03))
        packet.payload.writeBytes(bytes)
    }
}
