import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO
import CSQLite
import CPackagingRust
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct ProbeError: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ProbeError(description: message) }
}
func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
final class Database {
    var handle: OpaquePointer?
    init(_ path: String) throws {
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw ProbeError(description: "SQLite open failed: \(status)")
        }
    }
    deinit { sqlite3_close(handle) }
    func exec(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "SQLite: \(String(cString: sqlite3_errmsg(handle)))")
    }
    func scalar(_ sql: String) throws -> String {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, "SQLite prepare failed")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement) == SQLITE_ROW, "SQLite query returned no row")
        guard let value = sqlite3_column_text(statement, 0) else { throw ProbeError(description: "SQLite unexpected NULL") }
        return String(cString: value)
    }
    func configure() throws {
        try check(try scalar("PRAGMA journal_mode=WAL") == "wal", "WAL unavailable")
        try exec("PRAGMA synchronous=FULL")
        try check(try scalar("PRAGMA synchronous") == "2", "FULL sync unavailable")
    }
}
// An abrupt process exit must retain the committed row and discard id=2.
func crashWriter(_ path: String) throws {
    let db = try Database(path)
    try db.configure()
    try db.exec("CREATE TABLE relay(id INTEGER PRIMARY KEY, value TEXT, raw BLOB); BEGIN IMMEDIATE; INSERT INTO relay VALUES(1,'18446744073709551615',x'00FF8041'); COMMIT; BEGIN IMMEDIATE; INSERT INTO relay VALUES(2,'uncommitted',x'01')")
    try emit(["state": "ready_for_kill", "journal_mode": "wal", "synchronous": "FULL"])
    while true { sleep(1) }
}
func recover(_ path: String) throws {
    let db = try Database(path)
    try db.configure()
    try check(try db.scalar("SELECT COUNT(*) FROM relay") == "1", "wrong recovered row count")
    try check(try db.scalar("SELECT value || ':' || hex(raw) FROM relay WHERE id=1") == "18446744073709551615:00FF8041", "recovered data differs")
    try check(try db.scalar("PRAGMA integrity_check") == "ok", "SQLite integrity check failed")
    // A separate connection must be fenced while the first owns the WAL writer.
    let other = try Database(path)
    try db.exec("BEGIN IMMEDIATE")
    try check(sqlite3_exec(other.handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_BUSY, "SQLite writer locking failed")
    try db.exec("ROLLBACK")
    try check(try db.scalar("PRAGMA wal_checkpoint(TRUNCATE)") == "0", "WAL checkpoint busy")
    try emit(["result": "passed", "sqlite": String(cString: sqlite3_libversion()), "recovery": "committed_only", "writer_lock": "passed", "checkpoint": "passed"])
}
func smoke(host: String, ca: String) throws {
    let result = packaging_rust_self_test()
    try check(result != 0, "Rust codec/zstd exercise failed")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    try loop.scheduleTask(in: .milliseconds(10)) { () }.futureResult.wait()
    let address = try SocketAddress.makeAddressResolvingHost(host, port: 3306)
    func connect(serverName: String, trust: NIOSSLTrustRoots) throws -> MySQLConnection {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.trustRoots = trust
        return try MySQLConnection.connect(to: address, username: "probe", database: "probe", password: "packaging-only", tlsConfiguration: tls, serverHostname: serverName, on: loop).wait()
    }
    let connection = try connect(serverName: host, trust: .file(ca))
    defer { try? connection.close().wait() }
    let rows = try connection.simpleQuery("SELECT CAST(18446744073709551615 AS UNSIGNED) AS exact_value").wait()
    try check(rows.first?.column("exact_value")?.string == "18446744073709551615", "MySQL value mismatch")
    let cipher = try connection.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").wait()
    try check(!(cipher.first?.column("Value")?.string ?? "").isEmpty, "MySQL session has no TLS cipher")
    for (name, trust) in [("wrong-host.invalid", NIOSSLTrustRoots.file(ca)), (host, NIOSSLTrustRoots.certificates([]))] {
        var accepted = false
        do { let unexpected = try connect(serverName: name, trust: trust); try unexpected.close().wait(); accepted = true }
        catch {
            let diagnostic = String(describing: error)
            if name == host {
                try check(diagnostic.contains("CERTIFICATE_VERIFY_FAILED"), "untrusted-CA attempt failed for a different reason: \(diagnostic)")
            } else {
                try check(diagnostic.contains("failedToValidateHostname"), "hostname attempt failed for a different reason: \(diagnostic)")
            }
            try emit(["tls_rejection": name == host ? "untrusted_ca" : "wrong_hostname", "diagnostic": diagnostic])
        }
        try check(!accepted, "TLS accepted invalid peer")
    }
    let finalRows = try connection.simpleQuery("SELECT 1 AS still_connected").wait()
    try check(finalRows.first?.column("still_connected")?.string == "1", "positive connection failed after negative TLS tests")
    try emit(["result": "passed", "rust_events": result >> 32, "rust_rows": result & 0xffffffff,
              "zstd_roundtrip": "passed", "dns": "passed", "nio_timer": "passed", "mysql_tls": "verified",
              "sqlite": String(cString: sqlite3_libversion()), "architecture": "x86_64-linux-musl"])
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 3 && args[0] == "smoke" { try smoke(host: args[1], ca: args[2]) }
    else if args.count == 2 && args[0] == "crash-writer" { try crashWriter(args[1]) }
    else if args.count == 2 && args[0] == "recover" { try recover(args[1]) }
    else { throw ProbeError(description: "usage: packaging-probe smoke HOST CA | crash-writer DB | recover DB") }
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
