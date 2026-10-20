import CSQLite
import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

final class ResumeTests: XCTestCase {
    let target = "00000000-0000-0000-0000-000000000001"
    var helper: ApplyTests {
        #if os(Linux)
            return ApplyTests(name: "fixtures", testClosure: { _ in })
        #else
            return ApplyTests()
        #endif
    }
    func config(_ path: String, mode: String = "gtid", gtids: String? = nil, lowerCaseTableNames: Int = 0) throws
        -> ApplyConfiguration
    {
        let h = helper
        let source: [String: Any] = [
            "version": 2, "host": "source", "port": 3306, "username": "capture",
            "passwordEnvironment": "SOURCE_PASSWORD", "serverHostname": "source", "serverID": 9001, "sourceUUID": h.sid,
            "mode": mode, "lowerCaseTableNames": lowerCaseTableNames,
            "start": ["file": "binlog.000003", "position": 1589, "executedGTIDs": gtids ?? h.sid + ":1-10"],
        ]
        let object: [String: Any] = [
            "version": 2, "stateDirectory": path, "source": source,
            "target": [
                "preserveSourceGTIDs": false, "host": "target57", "port": 3306, "username": "apply",
                "passwordEnvironment": "TARGET_PASSWORD", "serverHostname": "target57", "nativeAutoStartDisabled": true,
            ],
        ]
        return try JSONDecoder().decode(ApplyConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func directory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("state")
    }
    func write(_ directory: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard
            sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil)
                == SQLITE_OK
        else { throw ApplyError("test SQLite open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ApplyError("test SQLite write") }
    }
    func seed(_ c: ApplyConfiguration) throws {
        let store = try StateStore(configuration: c)
        try store.bindTargetIdentity(target)
        try store.running()
        try store.stopped()
    }
    func apply(_ group: CompleteTransaction, to store: StateStore) throws {
        let table = helper.tables()[0]
        try store.schema(table, event: group.events.first(where: { $0.eventType == 19 })!, coordinate: group.start)
        for event in group.events {
            try store.append(
                LiveRecord(
                    kind: "event", file: group.start.file, observedPosition: String(event.nextPosition), event: event,
                    rawBase64: nil))
        }
        try store.begin(group)
        let plan = try DMLPlan.make(group, tables: [table])
        for (index, row) in plan.enumerated() {
            try store.intent(index, row)
            try store.rowDone(index)
        }
        try store.complete(group, rowCount: plan.count)
    }
    func testOperationCountersSurviveRestart() throws {
        let path = try directory()
        let c = try config(path.path)
        var expected: ApplyCounters?
        do {
            let store = try StateStore(configuration: c)
            try store.bindTargetIdentity(target)
            try store.running()
            let groups = try helper.groups()
            for group in groups { try apply(group, to: store) }
            expected = store.counters
            XCTAssertGreaterThan(store.counters.processedBinlogBytes, 0)
            XCTAssertEqual(
                store.counters.insertRows + store.counters.updateRows + store.counters.deleteRows, Int64(store.rows))
            XCTAssertEqual(store.counters.dmlTransactions, Int64(groups.count))
            try store.stopped()
        }
        let resumed = try StateStore(configuration: c, initialize: false)
        XCTAssertEqual(resumed.counters, expected)
    }
    func testSavedFiltersUseExactUTF8Spelling() throws {
        let path = try directory()
        var c = try config(path.path)
        c.replicateWildDoTable = ["poc.\u{e9}"]
        try seed(c)
        c.replicateWildDoTable = ["poc.e\u{301}"]
        XCTAssertThrowsError(try StateStore(configuration: c, initialize: false))
        c.replicateWildDoTable = ["poc.\u{e9}", "poc.e\u{301}"]
        let both = try c.filterIdentity()
        c.replicateWildDoTable = ["poc.\u{e9}"]
        XCTAssertNotEqual(Data(both.utf8), Data(try c.filterIdentity().utf8))
    }
    func testIncludeFiltersArePinnedAcrossRestart() throws {
        let path = try directory()
        var c = try config(path.path)
        c.replicateWildDoTable = ["poc.%"]
        try seed(c)
        do { _ = try StateStore(configuration: c, initialize: false) }
        c.replicateWildDoTable = ["other.%"]
        XCTAssertThrowsError(try StateStore(configuration: c, initialize: false)) {
            XCTAssertTrue(String(describing: $0).contains("filters differ"))
        }
    }
    func testResumeUsesSavedGTIDOnlyBaselineEvenIfConfigStartChanges() throws {
        let path = try directory()
        let original = try helper.config(path.path)
        try seed(original)
        let stale = try config(path.path, gtids: helper.sid + ":1-999")
        let resumed = try StateStore(configuration: stale, initialize: false)
        let capture = try resumed.captureConfiguration(stale.source)
        XCTAssertNil(capture.start.file)
        XCTAssertNil(capture.start.position)
        XCTAssertEqual(capture.start.executedGTIDs, helper.sid + ":1-10")
        XCTAssertEqual(resumed.transactions, 0)
        XCTAssertThrowsError(try resumed.bindTargetIdentity("00000000-0000-0000-0000-000000000002"))
        try resumed.bindTargetIdentity(target)
        XCTAssertEqual(
            try helper.sqlite(path.appendingPathComponent("state.sqlite"), "SELECT lifecycle,diagnostic FROM state"),
            [["STOPPED", "NULL"]])
    }
    func testEmptyAppliedProgressUsesSavedFilePositionAndEmptyGTIDBaseline() throws {
        let path = try directory()
        let c = try config(path.path, mode: "file-position", gtids: "")
        try seed(c)
        let resumed = try StateStore(configuration: c, initialize: false)
        let capture = try resumed.captureConfiguration(c.source)
        XCTAssertEqual(capture.start.file, "binlog.000003")
        XCTAssertEqual(capture.start.position, 1589)
        XCTAssertEqual(capture.start.executedGTIDs, "")
        guard case .position = try capture.validate() else { return XCTFail("wrong dump protocol") }
    }
    func testResumeRestoresAppliedBoundarySchemasCountersAndAppendsWithoutReplay() throws {
        for mode in ["gtid", "file-position"] {
            let path = try directory()
            let c = try config(path.path, mode: mode)
            let groups = try helper.groups()
            var store: StateStore? = try StateStore(configuration: c)
            try store!.bindTargetIdentity(target)
            try store!.running()
            try apply(groups[0], to: store!)
            try store!.stopped()
            let length = store!.relayLength
            store = nil
            let resumed = try StateStore(configuration: c, initialize: false)
            let capture = try resumed.captureConfiguration(c.source)
            XCTAssertEqual(capture.start.file, groups[0].end.file)
            XCTAssertEqual(capture.start.position, UInt32(groups[0].end.position))
            XCTAssertEqual(capture.start.executedGTIDs, helper.sid + ":1-11")
            XCTAssertEqual(resumed.transactions, 1)
            XCTAssertEqual(resumed.rows, 1)
            XCTAssertEqual(resumed.currentSchemas, helper.tables())
            XCTAssertEqual(resumed.relayLength, length)
            XCTAssertThrowsError(try resumed.begin(groups[0]))
            try resumed.running()
            try apply(groups[1], to: resumed)
            try resumed.stopped()
            XCTAssertEqual(resumed.transactions, 2)
            XCTAssertEqual(resumed.gtids, helper.sid + ":1-12")
            XCTAssertGreaterThan(resumed.relayLength, length)
            XCTAssertEqual(
                try helper.sqlite(
                    path.appendingPathComponent("state.sqlite"), "SELECT COUNT(*) FROM schemas WHERE current=1"),
                [["1"]])
        }
    }
    func testInitializationResumeAndWriterOwnershipAreDistinct() throws {
        let path = try directory()
        let c = try config(path.path)
        XCTAssertThrowsError(try StateStore(configuration: c, initialize: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        var store: StateStore? = try StateStore(configuration: c)
        try store!.bindTargetIdentity(target)
        try store!.stopped()
        XCTAssertThrowsError(try StateStore(configuration: c))
        XCTAssertThrowsError(try StateStore(configuration: c, initialize: false)) {
            XCTAssertTrue(String(describing: $0).contains("active writer"))
        }
        store = nil
        XCTAssertNoThrow(try StateStore(configuration: c, initialize: false))
    }
    func testResumeRestoresMoreThan64TableSchemas() throws {
        let path = try directory()
        let c = try config(path.path)
        let group = try helper.groups()[0]
        var store: StateStore? = try StateStore(configuration: c)
        try store!.bindTargetIdentity(target)
        try store!.running()
        let event = group.events.first(where: { $0.eventType == 19 })!
        let columns = helper.tables()[0].columns
        for index in 0..<160 {
            let table = ApplyTable(
                database: "poc", table: "capacity_\(index)", columns: columns, primaryKey: helper.tables()[0].primaryKey
            )
            try store!.schema(table, event: event, coordinate: group.start)
        }
        try store!.stopped()
        store = nil
        let resumed = try StateStore(configuration: c, initialize: false)
        XCTAssertEqual(resumed.currentSchemas.count, 160)
        XCTAssertEqual(Set(resumed.currentSchemas.map(\.table)), Set((0..<160).map { "capacity_\($0)" }))
    }
    func testUnsafeOrInconsistentSavedStateIsRejectedWithoutChangingLifecycle() throws {
        let corruptions = [
            "UPDATE state SET lifecycle='BLOCKED',diagnostic='target failed'",
            "UPDATE state SET lifecycle='RUNNING'",
            "UPDATE state SET active_gtid='pending'",
            "UPDATE state SET source_uuid='00000000-0000-0000-0000-000000000002'",
            "UPDATE state SET target_uuid=NULL",
            "UPDATE state SET applied_position='1589'",
            "UPDATE state SET transactions_applied=1",
            "UPDATE state SET durable_relay_length=99",
            "PRAGMA user_version=99",
            "DELETE FROM snapshots",
            "UPDATE snapshots SET gtids=''",
            "UPDATE snapshots SET source_file='binlog.000004',source_position='4'",
            "INSERT INTO ddl_intents(gtid,target_sql,status,created_at) VALUES('pending','CREATE TABLE x(id INT)','PENDING','now')",
        ]
        for sql in corruptions {
            let path = try directory()
            let c = try config(path.path)
            try seed(c)
            try write(path, sql)
            let db = path.appendingPathComponent("state.sqlite")
            let before = try helper.sqlite(db, "SELECT lifecycle,diagnostic FROM state")
            XCTAssertThrowsError(try StateStore(configuration: c, initialize: false), sql)
            XCTAssertEqual(try helper.sqlite(db, "SELECT lifecycle,diagnostic FROM state"), before)
        }
    }
    func testResumeUsesCoveringSnapshotAfterCompletedHistoryIsPruned() throws {
        let path = try directory()
        let c = try config(path.path)
        let group = try helper.groups()[0]
        var store: StateStore? = try StateStore(configuration: c)
        try store!.bindTargetIdentity(target)
        try apply(group, to: store!)
        try store!.stopped()
        store = nil
        try write(path, "DELETE FROM row_intents; DELETE FROM groups; DELETE FROM snapshots WHERE covered_sequence=0")
        let resumed = try StateStore(configuration: c, initialize: false)
        XCTAssertEqual(resumed.gtids, helper.sid + ":1-11")
        XCTAssertEqual(resumed.applied, group.end)
    }
}
