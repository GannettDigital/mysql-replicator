import XCTest
import CSQLite
import ReplicatorCodec
@testable import ReplicatorApply

extension ApplyTests {
    func testFinalRowAndCheckpointCommitTogetherOrNeitherDoes() throws {
        let helper = self
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let store = try StateStore(configuration:helper.config(parent.appendingPathComponent("state").path))
        let group = try helper.groups()[0]
        try store.schema(helper.tables()[0],event:group.events.first(where:{$0.eventType == 19})!,coordinate:group.start)
        try store.begin(group)
        try store.intent(0,DMLPlan.make(group,tables:helper.tables())[0])
        let path = store.directory.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        // Fail AFTER the row status update, inside the same SQLite transaction.
        XCTAssertEqual(sqlite3_exec(db,"CREATE TRIGGER fail_checkpoint BEFORE UPDATE OF transactions_applied ON state BEGIN SELECT RAISE(ABORT,'injected failure'); END",nil,nil,nil),SQLITE_OK)
        XCTAssertThrowsError(try store.complete(group,rowCount:1,finalRow:0))
        XCTAssertEqual(try helper.sqlite(path,"SELECT status FROM row_intents"),[["PENDING"]])
        XCTAssertEqual(try helper.sqlite(path,"SELECT status FROM groups"),[["PENDING"]])
        XCTAssertEqual(store.transactions,0)
        XCTAssertNotNil(store.pendingGTID)
        XCTAssertEqual(sqlite3_exec(db,"DROP TRIGGER fail_checkpoint",nil,nil,nil),SQLITE_OK)
        let commits = store.timings.snapshot["sqlite.commit"]!.count
        try store.complete(group,rowCount:1,finalRow:0)
        XCTAssertEqual(store.timings.snapshot["sqlite.commit"]!.count,commits+1)
        XCTAssertEqual(try helper.sqlite(path,"SELECT status FROM row_intents"),[["DONE"]])
        XCTAssertEqual(try helper.sqlite(path,"SELECT transactions_applied,active_gtid FROM state"),[["1","NULL"]])
        XCTAssertEqual(store.transactions,1)
    }

    func testFinalRowCannotHideMissingEarlierCompletion() throws {
        let helper = self
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let store = try StateStore(configuration:helper.config(parent.appendingPathComponent("state").path))
        let group = try helper.groups()[0], mutation = try DMLPlan.make(group,tables:helper.tables())[0]
        try store.schema(helper.tables()[0],event:group.events.first(where:{$0.eventType == 19})!,coordinate:group.start)
        try store.begin(group); try store.intent(0,mutation); try store.intent(1,mutation)
        XCTAssertThrowsError(try store.complete(group,rowCount:2,finalRow:1))
        XCTAssertEqual(try helper.sqlite(store.directory.appendingPathComponent("state.sqlite"),"SELECT status FROM row_intents ORDER BY ordinal"),[["PENDING"],["PENDING"]])
        try store.rowDone(0)
        try store.complete(group,rowCount:2,finalRow:1)
        XCTAssertEqual(store.rows,2)
    }

    func testDurableWritesDoNotEachTruncateWAL() throws {
        let helper = self
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let store = try StateStore(configuration:helper.config(parent.appendingPathComponent("state").path))
        let checkpoints = store.timings.snapshot["sqlite.checkpoint"]!.count
        for _ in 0..<10 { try store.running() }
        XCTAssertEqual(store.timings.snapshot["sqlite.checkpoint"]!.count,checkpoints)
        XCTAssertGreaterThan(store.walBytes,0)
        XCTAssertEqual(try helper.sqlite(store.directory.appendingPathComponent("state.sqlite"),"SELECT lifecycle FROM state"),[["RUNNING"]])
        try store.stopped()
        XCTAssertEqual(store.walBytes,0)
    }

    func testLockReuseRequiresSameSchemaAndBoundedTimeAndGroups() {
        let table = tables()[0]
        var epoch = TableLockEpoch(maximumGroups:2,maximumSeconds:0.05)
        XCTAssertFalse(epoch.canReuse(table,at:10))
        epoch.acquired(table,at:10)
        XCTAssertTrue(epoch.canReuse(table,at:10.01))
        var changed = table; changed.defaultCollation = "latin1_bin"
        XCTAssertFalse(epoch.canReuse(changed,at:10.01))
        epoch.completedGroup(); XCTAssertTrue(epoch.canReuse(table,at:10.02))
        epoch.completedGroup(); XCTAssertFalse(epoch.canReuse(table,at:10.02))
        epoch.acquired(table,at:11)
        XCTAssertFalse(epoch.canReuse(table,at:11.06))
        epoch.released(); XCTAssertNil(epoch.table)
    }

    func testTimingsRetainFailuresWithoutChangingThrownError() throws {
        let timings = StageTimings()
        XCTAssertEqual(timings.measure("outer") { timings.measure("inner") { 42 } },42)
        XCTAssertThrowsError(try timings.measure("outer") { throw ApplyError("original") }) {
            XCTAssertEqual(String(describing:$0),"original")
        }
        XCTAssertEqual(timings.snapshot["outer"]?.count,2)
        XCTAssertEqual(timings.snapshot["outer"]?.failures,1)
        XCTAssertEqual(timings.snapshot["inner"]?.count,1)
        XCTAssertGreaterThanOrEqual(timings.snapshot["outer"]!.seconds,timings.snapshot["inner"]!.seconds)
        XCTAssertNoThrow(try JSONEncoder().encode(timings.snapshot))
    }
}
