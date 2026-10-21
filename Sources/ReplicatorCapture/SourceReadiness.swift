import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import ReplicatorCodec

/// Checks the source without requesting a binlog stream or opening local state.
public enum SourceReadiness {
    public static func inspect(configuration config: CaptureConfiguration, password: String, contract: SourceContract)
        throws
    {
        _ = try config.validate()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let connection = try MySQLConnection.connect(
            to: SocketAddress.makeAddressResolvingHost(config.host, port: config.port),
            username: config.username, database: "", password: password,
            tlsConfiguration: config.tlsConfiguration(), serverHostname: config.serverHostname,
            requireTLS: config.requireTLS, handshakeTimeout: .seconds(10), on: group.next()
        ).wait()
        defer { try? connection.close().wait() }
        func query(_ sql: String) throws -> [MySQLRow] {
            let timeout = connection.eventLoop.scheduleTask(in: .seconds(10)) { _ = connection.close() }
            defer { timeout.cancel() }
            return try connection.simpleQuery(sql).wait()
        }
        try check(configuration: config, contract: contract, query: query)
        // This proves REPLICATION CLIENT access, but not permission to start a dump.
        _ = try query("SHOW BINARY LOGS")
    }

    static func check(
        configuration config: CaptureConfiguration, contract: SourceContract,
        query: (String) throws -> [MySQLRow]
    ) throws {
        let settings = try query(
            "SELECT @@server_uuid AS source_uuid,@@server_id AS server_id,@@GLOBAL.gtid_mode AS gtid_mode,@@GLOBAL.enforce_gtid_consistency AS gtid_consistency,@@GLOBAL.binlog_format AS binlog_format,@@GLOBAL.binlog_row_image AS row_image,@@GLOBAL.binlog_checksum AS checksum,VERSION() AS version"
        )
        guard let row = settings.first,
            row.column("source_uuid")?.string?.lowercased() == config.sourceUUID.lowercased(),
            row.column("server_id")?.string != String(config.serverID), row.column("gtid_mode")?.string == "ON",
            row.column("gtid_consistency")?.string == "ON", row.column("binlog_format")?.string == "ROW",
            row.column("row_image")?.string == "FULL", row.column("checksum")?.string == "CRC32",
            row.column("version")?.string?.hasPrefix(contract.rawValue) == true
        else {
            throw CaptureError(
                "source identity/settings differ from the qualified MySQL \(contract.rawValue) GTID-ON contract"
            )
        }
        let casing = try query("SELECT @@lower_case_table_names AS n")
        guard casing.first?.column("n")?.string == String(config.tableNameCaseSetting) else {
            throw CaptureError(
                "source lower_case_table_names differs from source.lowerCaseTableNames=\(config.tableNameCaseSetting)"
            )
        }
        let ssl = try query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        let encrypted = !(ssl.first?.column("Value")?.string ?? "").isEmpty
        guard encrypted == config.requireTLS else {
            throw CaptureError("source session TLS differs from configured transport")
        }
        let set = try GTIDSet(config.start.executedGTIDs)
        let covered = try query("SELECT GTID_SUBSET('\(set.canonical)',@@GLOBAL.gtid_executed) AS covered")
        guard covered.first?.column("covered")?.string == "1" else {
            throw CaptureError("bootstrap GTID set is not covered by this source")
        }
    }
}
