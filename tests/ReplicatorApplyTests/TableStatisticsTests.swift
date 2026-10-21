import CSQLite
import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

extension ApplyTests {
    func testTableStatisticsConfigurationBounds() throws {
        XCTAssertFalse(StatisticsPolicy().tableDetails)
        XCTAssertEqual(StatisticsPolicy().maximumTableEntries, 6000)
        for json in [
            "{\"maximumTableEntries\":0}", "{\"maximumTableEntries\":100001}", "{\"snapshotIntervalSeconds\":4}",
        ] {
            let policy = try JSONDecoder().decode(StatisticsPolicy.self, from: Data(json.utf8))
            XCTAssertThrowsError(try policy.validate())
        }
        let policy = try JSONDecoder().decode(
            StatisticsPolicy.self,
            from: Data("{\"tableDetails\":true,\"maximumTableEntries\":8000,\"snapshotIntervalSeconds\":60}".utf8))
        XCTAssertTrue(policy.tableDetails)
        XCTAssertEqual(policy.maximumTableEntries, 8000)
        XCTAssertNoThrow(try policy.validate())
    }

    func testTableStatisticsCountsOperationsFiltersSkipsAndTypes() throws {
        let statistics = TableStatistics(maximum: 6000)
        let groups = try groups()
        let table = tables()[0]
        statistics.schema(table)
        statistics.schema(table)
        var expected = ApplyCounters()
        for group in groups {
            group.events.forEach(statistics.observe)
            let mutations = try DMLPlan.make(group, tables: [table])
            statistics.plan(mutations)
            let delta = statistics.completing([.init(group: group, rows: mutations.count)])
            statistics.accept(delta)
            expected.complete(group, rows: mutations.count)
        }
        let entry = try XCTUnwrap(statistics.all.first { $0.table == table.table })
        XCTAssertEqual(entry.durable.insertRows, expected.insertRows)
        XCTAssertEqual(entry.durable.updateRows, expected.updateRows)
        XCTAssertEqual(entry.durable.deleteRows, expected.deleteRows)
        XCTAssertEqual(entry.process.plannedInsertRows, expected.insertRows)
        XCTAssertEqual(entry.process.plannedUpdateRows, expected.updateRows)
        XCTAssertEqual(entry.process.plannedDeleteRows, expected.deleteRows)
        XCTAssertEqual(entry.durable.completedTransactions, Int64(groups.count))
        XCTAssertEqual(Set(entry.process.columnTypes).count, entry.process.columnTypes.count)
        XCTAssertTrue(entry.process.indexTypes.contains("PRIMARY"))
        for outcome in [ApplyCounters.Outcome.filtered, .policySkipped, .errorSkipped] {
            statistics.accept(statistics.completing([.init(group: groups[0], rows: 0, outcome: outcome)]))
        }
        let skipped = try XCTUnwrap(statistics.all.first { $0.id == entry.id })
        XCTAssertEqual(skipped.durable.insertRows, expected.insertRows)
        XCTAssertEqual(skipped.durable.filteredTransactions, 1)
        XCTAssertEqual(skipped.durable.policySkippedTransactions, 1)
        XCTAssertEqual(skipped.durable.errorSkippedTransactions, 1)
        var filtered = try XCTUnwrap(groups[0].events.first { $0.eventType == 19 })
        filtered.replicationFiltered = true
        // A filtered row event carries no decoded rows. Do not report zero rows
        // as a measured row count for it.
        let event = DecodedEvent(
            offset: filtered.offset, eventSize: 20, control: nil, rowFlags: 1,
            replicationFiltered: true, eventType: 30, eventName: "WRITE_ROWS_EVENT",
            timestamp: 0, serverID: 1, nextPosition: 100, flags: 0, sha256: "",
            tableID: "1", database: table.database, table: table.table,
            number: nil, detailBase64: nil, detailText: nil, rows: [], rawBase64: nil)
        statistics.observe(event)
        XCTAssertEqual(statistics.all.first { $0.id == entry.id }?.process.filteredRowEventsWithoutRowCount, 1)
    }

    func testTableStatisticsWarningOverflowPagingAndNameBytes() throws {
        var warnings: [Int] = []
        let statistics = TableStatistics(maximum: 2, warning: { warnings.append($0) })
        statistics.query(seconds: 0.5, schema: true, table: .init(database: "db", table: "é"), failed: false)
        XCTAssertTrue(warnings.isEmpty)
        statistics.query(seconds: 0.5, schema: true, table: .init(database: "db", table: "e\u{301}"), failed: true)
        XCTAssertEqual(warnings, [2])
        for i in 0..<1000 {
            statistics.query(seconds: 1, schema: true, table: .init(database: "db", table: "t\(i)"), failed: false)
        }
        XCTAssertEqual(warnings, [2])
        XCTAssertEqual(statistics.summary.namedEntries, 2)
        XCTAssertEqual(statistics.all.count, 4)
        XCTAssertEqual(statistics.all.first { $0.id == -1 }?.process.schemaQueries, 1000)
        XCTAssertEqual(statistics.page(offset: 0, limit: 2).nextOffset, 2)
        XCTAssertEqual(statistics.page(offset: 2, limit: 2).entries.count, 2)
        XCTAssertNil(statistics.page(offset: 4, limit: 2).nextOffset)
        let restored = TableStatistics(maximum: 2, warning: { warnings.append($0) })
        try restored.restore(statistics.all, since: 4, omitted: 0)
        XCTAssertEqual(warnings, [2, 2])  // One warning per process, including a full restored registry.
        XCTAssertEqual(restored.summary.namedEntries, 2)
    }

    func testTableStatisticsSixThousandNamesKeepDefaultStatusSmall() throws {
        var warnings = 0
        let statistics = TableStatistics(maximum: 6000, warning: { _ in warnings += 1 })
        for i in 0..<6001 {
            statistics.query(seconds: 0, schema: true, table: .init(database: "db", table: "t\(i)"), failed: false)
        }
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(statistics.all.count, 6002)
        XCTAssertLessThan(try JSONEncoder().encode(statistics.summary).count, 512)
        XCTAssertLessThan(try JSONEncoder().encode(statistics.page(offset: 0, limit: 100)).count, 200000)
    }

    func testTableStatisticsBatchRollbackDoesNotPublishOrPersistAppliedCounts() throws {
        try withBatchFixture(statistics: true) { store, batch in
            let path = store.directory.appendingPathComponent("state.sqlite")
            try store.beginBatch(batch)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            func execute(_ sql: String) { XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK) }
            execute(
                "CREATE TRIGGER injected BEFORE UPDATE OF applied_sequence ON state BEGIN SELECT RAISE(ABORT,'fixture failure'); END"
            )
            let commits = store.timings.snapshot["sqlite.commit"]!.count
            XCTAssertThrowsError(try store.finishBatch(acknowledgedRows: batch.map { $0.mutations.count }))
            XCTAssertEqual(store.transactions, 0)
            XCTAssertTrue(store.tableStatistics!.all.allSatisfy { $0.durable.completedTransactions == 0 })
            let saved = try sqlite(path, "SELECT entry_json FROM table_statistics").map {
                try JSONDecoder().decode(TableStatisticsEntry.self, from: Data($0[0].utf8))
            }
            XCTAssertTrue(saved.allSatisfy { $0.durable.completedTransactions == 0 })
            execute("DROP TRIGGER injected")
            try store.finishBatch(acknowledgedRows: batch.map { $0.mutations.count })
            XCTAssertEqual(store.timings.snapshot["sqlite.commit"]!.count - commits, 1)
            XCTAssertEqual(
                store.tableStatistics!.all.reduce(0) { $0 + $1.durable.completedTransactions }, Int64(batch.count))
            XCTAssertThrowsError(try store.finishBatch(acknowledgedRows: batch.map { $0.mutations.count }))
            XCTAssertEqual(
                store.tableStatistics!.all.reduce(0) { $0 + $1.durable.completedTransactions }, Int64(batch.count))
            try store.block("fixture diagnostic")
            let blocked = try sqlite(path, "SELECT entry_json FROM table_statistics WHERE id=0")
            let entry = try JSONDecoder().decode(TableStatisticsEntry.self, from: Data(blocked[0][0].utf8))
            XCTAssertEqual(entry.process.blockedRuns, 1)
        }
    }

    func testTableStatisticsRenameDropKeepHistoricalNames() throws {
        let statistics = TableStatistics(maximum: 6)
        let table = tables()[0]
        let renamed = ApplyTable(
            database: table.database, table: "renamed", columns: table.columns,
            primaryKey: table.primaryKey)
        let name = TableName(database: table.database, table: table.table)
        let newName = TableName(database: table.database, table: renamed.table)
        let group = try groups()[0]
        let rename = PreparedDDL(statement: .rename(name, newName), before: table, after: renamed, sql: "unused")
        statistics.planDDL(rename)
        statistics.accept(statistics.completing([.init(group: group, rows: 0, ddl: rename)]))
        let drop = PreparedDDL(statement: .drop(newName), before: renamed, after: nil, sql: "unused")
        statistics.accept(statistics.completing([.init(group: group, rows: 0, ddl: drop)]))
        XCTAssertEqual(statistics.all.first { $0.table == table.table }?.durable.ddl, ["RENAME_TABLE": 1])
        XCTAssertEqual(
            statistics.all.first { $0.table == renamed.table }?.durable.ddl, ["RENAME_TABLE": 1, "DROP_TABLE": 1])
        XCTAssertEqual(statistics.all.first { $0.table == table.table }?.process.plannedDDL, ["RENAME_TABLE": 1])
    }
}

extension ResumeTests {
    func testTableStatisticsRestartRetainsAppliedButResetsProcessCounts() throws {
        let path = try directory()
        var c = try config(path.path)
        c.statistics = StatisticsPolicy()
        c.statistics?.tableDetails = true
        var before: [TableStatisticsEntry] = []
        var processID = ""
        do {
            let store = try StateStore(configuration: c)
            try store.bindTargetIdentity(target)
            try store.running()
            let group = try helper.groups()[0]
            group.events.forEach { store.tableStatistics?.observe($0) }
            try apply(group, to: store)
            store.tableStatistics?.failure()
            try store.stopped()
            before = store.tableStatistics!.all
            processID = store.tableStatistics!.processID
        }
        do {
            let store = try StateStore(configuration: c, initialize: false)
            XCTAssertNotEqual(store.tableStatistics!.processID, processID)
            for entry in store.tableStatistics!.all {
                XCTAssertEqual(entry.durable, before.first { $0.id == entry.id }?.durable)
                XCTAssertEqual(entry.process.observedEvents, 0)
                XCTAssertEqual(entry.process.blockedRuns, 0)
            }
            XCTAssertThrowsError(try store.begin(helper.groups()[0]))
            try store.stopped()
        }
        c.statistics?.tableDetails = false
        do {
            let store = try StateStore(configuration: c, initialize: false)
            try apply(helper.groups()[1], to: store)
            try store.stopped()
        }
        c.statistics?.tableDetails = true
        let store = try StateStore(configuration: c, initialize: false)
        XCTAssertEqual(store.tableStatistics?.summary.transactionsNotRecorded, 1)
    }
}
