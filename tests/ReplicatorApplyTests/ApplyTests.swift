import XCTest
import Foundation
import CSQLite
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

final class ApplyTests: XCTestCase {
    let sid = "8ba09bde-bc41-11f1-8272-ba06e9024a03"
    var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func config(_ path: String = "/tmp/unused-state", storage: [String:Any]? = nil, applierProfiling: Bool? = nil, collations: [String:String]? = nil, profile: String? = nil, skipErrors: [String:Any]? = nil, mode: String = "gtid") throws -> ApplyConfiguration {
        var object: [String:Any] = ["version":1,"stateDirectory":path,
            "source":["version":1,"host":"source","port":3306,"username":"capture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"source","serverID":9001,"sourceUUID":sid,"mode":"gtid","start":["executedGTIDs":sid+":1-10"],"tables":[["database":"poc","table":"items","columns":["signed","utf8","unsigned"]]]],
            "target":["host":"target57","port":3306,"username":"apply","passwordEnvironment":"TARGET_PASSWORD","serverHostname":"target57","nativeAutoStartDisabled":true],
            "tables":[["database":"poc","table":"items","primaryKey":"id","columns":[["name":"id","type":"int","nullable":false],["name":"value","type":"varchar(100)","nullable":false,"collation":"utf8mb4_unicode_ci"],["name":"quantity","type":"bigint unsigned","nullable":false]]]]]
        object["storage"]=storage
        object["profile"]=profile
        object["skipErrors"]=skipErrors
        object["applierProfiling"]=applierProfiling
        if let collations { object["compatibility"] = ["collations":collations] }
        object["version"]=2; object.removeValue(forKey:"tables")
        var source=object["source"] as! [String:Any]; source["mode"]=mode; if mode == "file-position" { source["start"]=["file":"binlog.000001","position":4,"executedGTIDs":sid+":1-10"] }; source["version"]=2; source.removeValue(forKey:"tables"); object["source"]=source
        return try JSONDecoder().decode(ApplyConfiguration.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func tables() -> [ApplyTable] {
        [ApplyTable(database:"poc",table:"items",columns:[ApplyColumn(name:"id",type:"int",nullable:false,collation:nil),ApplyColumn(name:"value",type:"varchar(100)",nullable:false,collation:"utf8mb4_unicode_ci"),ApplyColumn(name:"quantity",type:"bigint unsigned",nullable:false,collation:nil)],primaryKey:"id")]
    }
    func groups() throws -> [CompleteTransaction] {
        let history = try JSONDecoder().decode(SchemaHistory.self,from:Data(contentsOf:root.appendingPathComponent("tests/ReplicatorCodecTests/Schema/source-positive.json")))
        var groups: [CompleteTransaction] = []
        try Inspection.inspectTransactions(file:root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),sourceFile:"binlog.000003",history:history,includeRaw:true) { if $0.start.position >= 1589 { groups.append($0) } }
        return groups
    }
    func testCleanStopRequiresTypedCancellationAndNoPendingCaptureOrApply() throws {
        func error(_ cause: Error, pending: BinlogCoordinate? = nil) -> LiveInspectionError {
            LiveInspectionError(error:cause,summary:LiveSummary(transactions:0,events:0,eventBytesReceived:"0",heartbeats:0,rotationAnnouncements:0,lastCompleteBoundary:nil,pendingTransactionStart:pending,completeGTIDSet:sid+":1-10"))
        }
        XCTAssertTrue(ApplyRun.canStopCleanly(error(CaptureCancelled()),pendingGTID:nil))
        XCTAssertFalse(ApplyRun.canStopCleanly(error(CaptureCancelled(),pending:.init(file:"binlog.000003",position:1589)),pendingGTID:nil))
        XCTAssertFalse(ApplyRun.canStopCleanly(error(CaptureCancelled()),pendingGTID:sid+":11"))
        XCTAssertFalse(ApplyRun.canStopCleanly(error(CaptureError("live inspection cancelled")),pendingGTID:nil))
        XCTAssertFalse(ApplyRun.canStopCleanly(error(ApplyError("target write failed")),pendingGTID:nil))
    }
    func testIdleStopPersistsBaselineAndPendingApplyCannotBeStopped() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let store = try StateStore(configuration:config(parent.appendingPathComponent("state").path))
        try store.running(); try store.stopped()
        let db = store.directory.appendingPathComponent("state.sqlite")
        XCTAssertEqual(try sqlite(db,"SELECT lifecycle,transactions_applied,active_gtid,diagnostic,applied_position FROM state"),[["STOPPED","0","NULL","NULL","NULL"]])
        XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-10")
        try store.running(); try store.begin(groups()[0])
        XCTAssertThrowsError(try store.stopped())
        try store.block("apply cancelled")
        XCTAssertEqual(try sqlite(db,"SELECT lifecycle,active_gtid,diagnostic FROM state"),[["BLOCKED",sid+":11","apply cancelled"]])
    }
    func testRecordedDMLPlanPreservesValuesOrderAndSourceIdentity() throws {
        let c = try config(); try c.validate()
        let plans = try groups().flatMap { try DMLPlan.make($0,tables:tables()) }
        XCTAssertEqual(plans.map { $0.row.operation },["insert","update","delete","update"])
        XCTAssertEqual(plans[0].row.after,[.signed(3),.text("inserted"),.unsigned(UInt64.max)])
        XCTAssertEqual(plans[1].row.before,[.signed(1),.text("seed-one"),.unsigned(1)])
        XCTAssertEqual(plans.map(\.rowIndex),[0,0,0,0])
    }
    func testMultiStatementGroupRejectedBeforePlanningAnyMutation() throws {
        let c = try config(), g = try groups()
        let combined = CompleteTransaction(start:g[0].start,end:g[1].end,gtid:g[0].gtid,anonymous:false,outcome:.committed,events:g[0].events + g[1].events)
        XCTAssertThrowsError(try DMLPlan.make(combined,tables:tables()))
        let opaque = CompleteTransaction(start:g[0].start,end:g[0].end,gtid:g[0].gtid,anonymous:false,outcome:.statement,events:g[0].events)
        XCTAssertThrowsError(try DMLPlan.make(opaque,tables:tables()))
    }
    func testEmptyCommittedGroupHasNoMutationsButRollbackIsNotACommit() throws {
        let g=try groups()[0]
        let empty=g.events.filter{$0.rowFlags == nil && $0.eventType != 19}
        let committed=CompleteTransaction(start:g.start,end:g.end,gtid:g.gtid,anonymous:false,outcome:.committed,events:empty)
        XCTAssertTrue(try DMLPlan.make(committed,tables:[]).isEmpty)
        let rollback=CompleteTransaction(start:g.start,end:g.end,gtid:g.gtid,anonymous:false,outcome:.rolledBack,events:empty)
        XCTAssertThrowsError(try DMLPlan.make(rollback,tables:[]))
    }
    func testFullImageTypesNullAndLengthAreStrict() throws {
        let c = tables()[0].columns
        XCTAssertThrowsError(try c[0].validate(.signed(Int64(Int32.max)+1)))
        XCTAssertThrowsError(try c[2].validate(.signed(-1)))
        XCTAssertThrowsError(try c[2].validate(.absent))
        XCTAssertThrowsError(try c[1].validate(.null))
        XCTAssertThrowsError(try c[1].validate(.text(String(repeating:"a",count:101))))
        XCTAssertNoThrow(try c[1].validate(.text("quotes '\\ emoji 🐈 \0")))
        XCTAssertNoThrow(try c[2].validate(.unsigned(UInt64.max)))
    }
    func testGTIDOnlyConfigurationDoesNotInventPosition() throws {
        let c = try config(); try c.validate()
        XCTAssertNil(c.source.start.file); XCTAssertNil(c.source.start.position)
        let p = try StreamProcessor(config:c.source,includeRaw:false,emitEvent:{_ in},emitTransaction:{_ in})
        XCTAssertTrue(p.atOrAfterBootstrap(BinlogCoordinate(file:"binlog.000123",position:123)))
    }
    func sqlite(_ path: URL, _ sql: String) throws -> [[String]] {
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path,&db,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db,sql,-1,&stmt,nil),SQLITE_OK)
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt,i).map { String(cString:$0) } ?? "NULL" })
        }
        return rows
    }
    func testJournalRetainsRawBytesAndDoesNotAdvanceBeforeWholeGroup() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let c = try config(parent.appendingPathComponent("state").path)
        let store = try StateStore(configuration:c)
        XCTAssertThrowsError(try StateStore(configuration:c))
        let group = try groups()[0]
        for event in group.events {
            try store.append(LiveRecord(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil))
        }
        try store.schema(tables()[0],event:group.events.first(where:{$0.eventType == 19})!,coordinate:group.start)
        try store.begin(group)
        let mutation = try DMLPlan.make(group,tables:tables())[0]
        try store.intent(0,mutation)
        let db = store.directory.appendingPathComponent("state.sqlite")
        XCTAssertEqual(try sqlite(db,"SELECT transactions_applied,rows_applied,applied_file,active_gtid FROM state"),[["0","0","NULL",sid+":11"]])
        XCTAssertEqual(try sqlite(db,"SELECT status,source_event_offset FROM row_intents"),[["PENDING",mutation.eventOffset]])
        XCTAssertThrowsError(try store.complete(group,rowCount:1))
        try store.rowDone(0)
        XCTAssertEqual(try sqlite(db,"SELECT transactions_applied FROM state"),[["0"]])
        try store.complete(group,rowCount:1)
        XCTAssertEqual(try sqlite(db,"SELECT transactions_applied,rows_applied,applied_position FROM state"),[["1","1","1885"]])
        XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-11")
        XCTAssertThrowsError(try store.begin(group))
        try store.block("test diagnostic")
        XCTAssertEqual(try sqlite(db,"SELECT lifecycle,diagnostic FROM state"),[["BLOCKED","test diagnostic"]])
        let raw = try Data(contentsOf:store.directory.appendingPathComponent("relay.frames"))
        XCTAssertNotNil(raw.range(of:Data(base64Encoded:group.events[0].rawBase64!)!))
        let columns = try sqlite(db,"SELECT name FROM pragma_table_info('row_intents')").flatMap{$0}
        XCTAssertEqual(columns,["gtid","ordinal","source_event_offset","source_row","schema_id","status","created_at","completed_at"])
    }
    func testHistoryPrunesOnlyUnderPressureAfterMinimumAgeAndPreservesCoverage() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let c = try config(parent.appendingPathComponent("state").path,storage:["historyRetentionSeconds":60,"snapshotEveryTransactions":100])
        var time = Date(timeIntervalSince1970:1_700_000_000)
        var free = Int64.max/4
        let store = try StateStore(configuration:c,now:{time},freeDisk:{_ in free})
        let groups = try groups()
        let db = store.directory.appendingPathComponent("state.sqlite")
        try store.schema(tables()[0],event:groups[0].events.first(where:{$0.eventType == 19})!,coordinate:groups[0].start)
        func apply(_ index: Int) throws {
            let g=groups[index]
            try store.begin(g)
            try store.intent(0,DMLPlan.make(g,tables:tables())[0])
            try store.rowDone(0); try store.complete(g,rowCount:1)
        }
        try apply(0)
        time.addTimeInterval(120)
        try store.ensureCapacity()
        XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM groups"),[["1"]],"age alone must not prune")
        try apply(1)
        try store.begin(groups[2])
        try store.intent(0,DMLPlan.make(groups[2],tables:tables())[0])
        let coverage=try store.durableAppliedGTIDs()
        free=c.policy.minimumFreeDiskBytes+c.policy.maximumSQLiteBytes*3/2
        try store.ensureCapacity()
        XCTAssertEqual(try sqlite(db,"SELECT gtid,status FROM groups ORDER BY sequence"),[[sid+":12","APPLIED"],[sid+":13","PENDING"]])
        XCTAssertEqual(try sqlite(db,"SELECT gtid,status FROM row_intents ORDER BY gtid"),[[sid+":12","DONE"],[sid+":13","PENDING"]])
        XCTAssertEqual(try store.durableAppliedGTIDs(),coverage)
        XCTAssertEqual(coverage,sid+":1-12")
        XCTAssertEqual(try sqlite(db,"SELECT transactions_applied,rows_applied,applied_position,last_applied_at FROM state"),[["2","2",String(groups[1].end.position),store.timestamp(time)]])
        // Pending work remains pinned even after it has aged past the cutoff.
        time.addTimeInterval(120)
        try store.ensureCapacity()
        XCTAssertEqual(try sqlite(db,"SELECT gtid,status FROM groups"),[[sid+":13","PENDING"]])
        XCTAssertEqual(try store.durableAppliedGTIDs(),coverage)
        XCTAssertLessThan(store.sqliteBytes,c.policy.maximumSQLiteBytes)
        free=c.policy.minimumFreeDiskBytes
        XCTAssertThrowsError(try store.ensureCapacity())
        XCTAssertEqual(try store.durableAppliedGTIDs(),coverage)
    }
    func testBusyReaderStopsBeforeWALCanGrowUnbounded() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let c=try config(parent.appendingPathComponent("state").path)
        var time = Date()
        let store=try StateStore(configuration:c,now:{time})
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(store.directory.appendingPathComponent("state.sqlite").path,&reader,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        defer {sqlite3_close(reader)}
        XCTAssertEqual(sqlite3_exec(reader,"BEGIN; SELECT * FROM state",nil,nil,nil),SQLITE_OK)
        try store.running()
        XCTAssertNoThrow(try store.ensureCapacity(), "a small WAL must not require immediate truncation")
        var blocked = false
        for _ in 0..<1000 {
            time.addTimeInterval(1) // Ensure a real page change even on a fast host.
            do { try store.running() }
            catch {
                XCTAssertTrue(String(describing:error).contains("WAL checkpoint blocked"))
                blocked = true; break
            }
        }
        XCTAssertTrue(blocked, "a pinned reader must stop writes at the WAL threshold")
        XCTAssertLessThan(store.sqliteBytes,c.policy.maximumSQLiteBytes)
        XCTAssertEqual(sqlite3_exec(reader,"ROLLBACK",nil,nil,nil),SQLITE_OK)
        XCTAssertNoThrow(try store.ensureCapacity())
        XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-10")
    }
    func testSQLiteHardBudgetStopsWhenYoungHistoryCannotBeEvicted() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let c=try config(parent.appendingPathComponent("state").path,storage:["maximumSQLiteBytes":8*1024*1024])
        let store=try StateStore(configuration:c,freeDisk:{_ in Int64.max/4})
        let path=store.directory.appendingPathComponent("state.sqlite")
        // Seed occupied pages without thousands of fsyncs; retention must not
        // evict unrelated/pinned data to make a full database writable.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE pinned(payload BLOB); INSERT INTO pinned VALUES(zeroblob(2600000))",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try store.ensureCapacity())
        XCTAssertLessThan(store.sqliteBytes,c.policy.maximumSQLiteBytes)
        XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-10")
    }
    func testTextRowEqualityPreservesUnicodeEncodingAndTrailingSpaces() {
        XCTAssertEqual("é","e\u{301}") // Swift's usual equivalence is too broad here.
        XCTAssertFalse(exactImage([.text("é")],[.text("e\u{301}")]))
        XCTAssertFalse(exactImage([.text("a")],[.text("a ")]))
        XCTAssertTrue(exactImage([.text("é"),.null],[.text("é"),.null]))
    }
    func testIdentifierQuotingDoesNotPermitSQLInjection() throws {
        XCTAssertEqual(try quoted("a`b; DROP TABLE x"),"`a``b; DROP TABLE x`")
        XCTAssertThrowsError(try quoted("a\0b"))
        XCTAssertThrowsError(try quoted(String(repeating:"a",count:65)))
    }
}
