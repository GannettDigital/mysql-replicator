import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ApplyTests {
    private func previewQuery(_ sql: String) -> QueryControl {
        .init(
            database: "poc", sql: Data(sql.utf8), errorCode: 0,
            statusVariables: Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 4, 45, 0, 224, 0, 224, 0, 18, 45, 0]))
    }
    private func previewMetadata(_ tables: [ApplyTable] = []) -> (TableName) throws -> ApplyTable? {
        { name in tables.first { $0.identity == name.identity } }
    }
    private func previewDDL(_ sql: String, sequence: String) throws -> CompleteTransaction {
        let template = try groups()[0]
        let identity = try SourceGTID(parsing: sid + ":" + sequence)
        func event(_ type: UInt32, _ control: BinlogControl) -> DecodedEvent {
            DecodedEvent(
                offset: "4", eventSize: 100, control: control, rowFlags: nil, eventType: type,
                eventName: "preview", timestamp: 0, serverID: 1, nextPosition: 104, flags: 0,
                sha256: "", tableID: nil, database: "poc", table: nil, number: nil,
                detailBase64: nil, detailText: nil, rows: [], rawBase64: nil)
        }
        let gtid = event(33, .gtid(identity))
        let query = event(2, .query(previewQuery(sql)))
        return .init(
            start: template.start, end: template.end, gtid: identity, anonymous: false,
            outcome: .statement, events: [gtid, query])
    }
    func testDryRunDDLDiscardsWritesAndLeavesStateUntouched() throws {
        let directory = URL(fileURLWithPath: "/tmp/preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("state.sqlite")
        let bytes = Data("production state must not be opened".utf8)
        try bytes.write(to: sentinel)
        var records: [DryRunRecord] = []
        let preview = try DryRunEngine(
            configuration: config(directory.path), offline: true, metadata: previewMetadata(tables()),
            targetVersion: 50742, packetLimit: 64 * 1024 * 1024, tokens: { try DDLTokens.lex($0.sql) },
            emit: { records.append($0) })
        for (sql, number) in [
            ("CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", "1"),
            (
                "CREATE TABLE poc.items (id INT NOT NULL PRIMARY KEY, value VARCHAR(80) NOT NULL, quantity BIGINT UNSIGNED NOT NULL)",
                "2"
            ),
            ("ALTER TABLE poc.items MODIFY value VARCHAR(100) NOT NULL", "3"),
        ] { try preview.transaction(previewDDL(sql, sequence: number)) }
        let group = try groups()[0]
        for event in group.events where event.eventType == 19 { _ = try preview.tableMap(event) }
        try preview.transaction(group)
        XCTAssertEqual(records.last?.executor, "sql")
        XCTAssertEqual(records.last?.operations["insert"], 1)
        XCTAssertEqual(preview.summary.transactionsInspected, 4)
        XCTAssertTrue(preview.summary.inspectedGTIDs.contains(":1-3:11"))
        try preview.transaction(previewDDL("DROP TABLE poc.items", sequence: "12"))
        XCTAssertTrue(preview.schema.tables.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.sqlite"])
    }
    func testDryRunDDLInvalidatesMetadataAndReadsUnchangedTarget() throws {
        var reads = 0
        let seed = tables()[0]
        let metadata: (TableName) throws -> ApplyTable? = { name in
            reads += 1
            return name.table == "items" ? seed : nil
        }
        let preview = try DryRunEngine(
            configuration: config(), offline: true, metadata: metadata,
            targetVersion: 50742, packetLimit: 65536, tokens: { try DDLTokens.lex($0.sql) }, emit: { _ in })
        let name = TableName(database: "poc", table: "items")
        _ = try preview.schema.table(name, read: metadata)
        _ = try preview.schema.table(name, read: metadata)
        XCTAssertEqual(reads, 1)
        for (index, sql) in [
            "ALTER TABLE poc.items ADD new_column INT",
            "RENAME TABLE poc.items TO poc.new_items",
            "DROP TABLE poc.items", "DROP DATABASE poc",
        ].enumerated() {
            try preview.transaction(previewDDL(sql, sequence: String(index + 1)))
            XCTAssertTrue(preview.schema.tables.isEmpty)
            XCTAssertEqual(try preview.schema.table(name, read: metadata)?.columns, seed.columns)
            XCTAssertEqual(reads, index + 2)
        }
    }
    func testDryRunCreateThenDMLCanFailWithoutChangingTargetOrCheckpoint() throws {
        let preview = try DryRunEngine(
            configuration: config(), offline: true, metadata: previewMetadata(),
            targetVersion: 50742, packetLimit: 65536, tokens: { try DDLTokens.lex($0.sql) }, emit: { _ in })
        try preview.transaction(previewDDL("CREATE DATABASE poc", sequence: "1"))
        try preview.transaction(previewDDL("CREATE TABLE poc.items (id INT PRIMARY KEY)", sequence: "2"))
        let group = try groups()[0]
        let tableMap = try XCTUnwrap(group.events.first { $0.eventType == 19 })
        XCTAssertThrowsError(try preview.recordFailure { try preview.tableMap(tableMap) }) {
            XCTAssertTrue($0 is DryRunUnresolved)
            XCTAssertTrue(String(describing: $0).contains("discarded DDL"))
        }
        XCTAssertTrue(preview.unresolved)
        XCTAssertEqual(preview.summary.transactionsInspected, 2)
        XCTAssertEqual(preview.summary.inspectedGTIDs, sid + ":1-2")
        XCTAssertTrue(preview.schema.tables.isEmpty)
    }
    func testSchemaMetadataCacheInvalidatesTablesAndDatabases() throws {
        let cache = SchemaMetadataCache()
        let original = tables()[0]
        let from = TableName(database: "poc", table: "items")
        let to = TableName(database: "poc", table: "renamed")
        let unrelated = TableName(database: "other", table: "items")
        var reads = 0
        func read(_ name: TableName) -> ApplyTable? {
            reads += 1
            return original.renamed(to: name)
        }
        for name in [from, to, unrelated] { _ = try cache.table(name, read: read) }
        cache.invalidate(from)
        cache.invalidate(to)
        XCTAssertEqual(cache.tables.count, 1)
        _ = try cache.table(from, read: read)
        _ = try cache.table(unrelated, read: read)
        XCTAssertEqual(reads, 4)
        cache.invalidate(database: "poc")
        XCTAssertNil(cache.tables[from.identity])
        XCTAssertNotNil(cache.tables[unrelated.identity])
        cache.invalidateAll()
        XCTAssertTrue(cache.tables.isEmpty)
    }
    func testDryRunAccessRejectsWritesLocksGTIDsAndScratchPaths() throws {
        for sql in [
            "INSERT INTO t VALUES(1)", "CREATE TEMPORARY TABLE t(id INT)", "SET GTID_NEXT='AUTOMATIC'",
            "SET SESSION sql_mode=''", "BEGIN", "COMMIT", "ROLLBACK", "LOCK TABLES t WRITE", "BINLOG 'x'",
            "SELECT GET_LOCK('mysql-replicator-writer',0)", "SELECT 1 INTO OUTFILE '/tmp/x'",
        ] {
            XCTAssertThrowsError(try DryRunAccess.check(sql, mutation: false, rawSQL: nil), sql)
        }
        for sql in [
            "SELECT @@max_allowed_packet AS v", "SHOW SESSION STATUS LIKE 'Ssl_cipher'",
            "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_NAME=?",
        ] {
            XCTAssertNoThrow(try DryRunAccess.check(sql, mutation: false, rawSQL: nil))
            XCTAssertThrowsError(try DryRunAccess.check(sql, mutation: true, rawSQL: nil))
            XCTAssertThrowsError(try DryRunAccess.check(sql, mutation: false, rawSQL: Data(sql.utf8)))
        }
    }
    func testDryRunArchiveFiltersAndEarlyStopUseCaptureRules() throws {
        let c = try config()
        let directory = URL(fileURLWithPath: "/tmp/dry-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),
            to: directory.appendingPathComponent("binlog.000003"))
        let archive = try ArchiveReplay(
            configuration: JSONDecoder().decode(
                ArchiveConfiguration.self,
                from: JSONSerialization.data(withJSONObject: ["directory": directory.path])), source: c.source,
            contract: .mysql84)
        var source = c.source
        source.stopAfterTransactions = 1
        for transport in ["sql", "binlog", "filtered"] {
            var records: [DryRunRecord] = []
            let preview = try DryRunEngine(
                configuration: config(transport: transport == "sql" ? "sql" : "binlog"),
                offline: true, metadata: previewMetadata(tables()), targetVersion: 50742, packetLimit: 65536,
                tokens: { try DDLTokens.lex($0.sql) }, emit: { records.append($0) })
            try archive.run(
                configuration: source, cancellation: .init(), retainRawBytes: true,
                emitEvent: preview.event, emitTransaction: preview.transaction, resolveSchema: nil, timings: .init(),
                ignoreTable: { _, _ in transport == "filtered" })
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].executor, transport == "filtered" ? "skip" : transport)
            XCTAssertEqual(preview.summary.rowsInspected, transport == "filtered" ? 0 : 1)
            XCTAssertEqual(preview.summary.transactionsInspected, 1)
        }
    }
}

extension ApplyTests {
    func testDryRunConnectionsKeepMetadataReadsSeparateFromDiscardedWrites() throws {
        let reader = DiscardTargetQueryConnection()
        let writer = DiscardTargetQueryConnection()
        let connections = TargetQueryConnections(reads: reader, writes: writer, metadataOnly: true)
        _ = try connections.execute(
            "SELECT @@max_allowed_packet AS v", binds: [], textProtocol: false, rawSQL: nil, mutation: false)
        for sql in [
            "SET GTID_NEXT='AUTOMATIC'", "CREATE TABLE t(id INT)", "INSERT INTO t VALUES(1)",
            "COMMIT", "SELECT GET_LOCK('writer',0)",
        ] {
            let result = try connections.execute(sql, binds: [], textProtocol: true, rawSQL: nil, mutation: false)
            XCTAssertTrue(result.0.isEmpty)
            XCTAssertNil(result.1)
        }
        _ = try connections.execute(
            "raw DDL", binds: [], textProtocol: true, rawSQL: Data([255]), mutation: true)
        XCTAssertThrowsError(
            try connections.execute(
                "SELECT * FROM application_table", binds: [], textProtocol: false, rawSQL: nil, mutation: false))
        XCTAssertEqual(reader.commandsDiscarded, 1)
        XCTAssertEqual(writer.commandsDiscarded, 6)
    }
}

extension ApplyTests {
    func testTargetConnectionsKeepSessionReadsOnWriter() throws {
        let reader = DiscardTargetQueryConnection()
        let writer = DiscardTargetQueryConnection()
        let connections = TargetQueryConnections(reads: reader, writes: writer, metadataOnly: false)
        for sql in [
            "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=?",
            "SELECT SERVICE_STATE FROM performance_schema.replication_applier_status",
        ] {
            XCTAssertTrue(connections.usesMetadataConnection(sql, mutation: false, rawSQL: nil, metadata: true))
            _ = try connections.execute(
                sql, binds: [], textProtocol: false, rawSQL: nil, mutation: false, metadata: true)
        }
        for sql in [
            "SELECT @@SESSION.GTID_NEXT AS v", "SELECT @@SESSION.sql_mode AS v",
            "SELECT IS_USED_LOCK('writer')=CONNECTION_ID() AS v", "SHOW CREATE TABLE t",
            "SELECT v FROM temporary_scratch_table",
            "SELECT `FROM INFORMATION_SCHEMA.foo` FROM application_table",
            "SELECT id FROM application_table FOR UPDATE",
            "SET SESSION sql_mode=''", "INSERT INTO t VALUES(1)", "COMMIT",
        ] {
            XCTAssertFalse(connections.usesMetadataConnection(sql, mutation: false, rawSQL: nil))
            _ = try connections.execute(sql, binds: [], textProtocol: true, rawSQL: nil, mutation: false)
        }
        XCTAssertEqual(reader.commandsDiscarded, 2)
        XCTAssertEqual(writer.commandsDiscarded, 10)
    }
}
