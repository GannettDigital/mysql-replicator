import XCTest
import CSQLite
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ApplyTests {
    func testApplierProfileCountsFailuresAndPreservesRelayBytes() throws {
        XCTAssertNil(try config().applierProfiling)
        var relay: [Data] = []
        for enabled in [false,true] {
            try withBatchFixture(profiling:enabled) { store,batch in
                relay.append(try Data(contentsOf:store.directory.appendingPathComponent("relay.frames")))
                try store.beginBatch(batch)
                XCTAssertThrowsError(try store.finishBatch(acknowledgedRows:[]))
                try store.finishBatch(acknowledgedRows:batch.map { $0.mutations.count })
                let detail=store.timings.snapshot.filter { $0.key.hasPrefix("apply.detail.") }
                if enabled {
                    XCTAssertEqual(detail["apply.detail.journal.prepare_batch"]?.count,1)
                    XCTAssertEqual(detail["apply.detail.journal.complete_batch"]?.count,2)
                    XCTAssertEqual(detail["apply.detail.journal.complete_batch"]?.failures,1)
                    XCTAssertEqual(detail["apply.detail.journal.gtid"]?.count,UInt64(batch.count*2))
                    XCTAssertEqual(detail["apply.detail.relay.metadata"]?.count,UInt64(batch.reduce(0) { $0+$1.group.events.count }))
                    XCTAssertEqual(detail["apply.detail.sqlite.prepare"]?.count,detail["apply.detail.sqlite.finalize"]?.count)
                    XCTAssertGreaterThan(detail["apply.detail.sqlite.step"]?.count ?? 0,0)
                } else { XCTAssertTrue(detail.isEmpty) }
            }
        }
        XCTAssertEqual(relay[0],relay[1])
    }

    private func batchFixture(_ store: StateStore) throws -> [PreparedDMLGroup] {
        try groups().map { group in
            try store.schema(tables()[0],event:group.events.first{$0.eventType == 19}!,coordinate:group.start)
            for event in group.events {
                try store.append(LiveRecord(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil))
            }
            return PreparedDMLGroup(group:group,mutations:try DMLPlan.make(group,tables:tables()),relayEnd:store.relayLength)
        }
    }
    private func withBatchFixture(profiling: Bool = false, _ body: (StateStore,[PreparedDMLGroup]) throws -> Void) throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let store=try StateStore(configuration:config(parent.appendingPathComponent("state").path,applierProfiling:profiling))
        try body(store,batchFixture(store))
    }
    func testBatchPreparesEveryIntentBeforeWritesAndCompletesWithTwoCommits() throws {
        for profiling in [false,true] {
            try withBatchFixture(profiling:profiling) { store,batch in
                let path=store.directory.appendingPathComponent("state.sqlite")
                let commits=store.timings.snapshot["sqlite.commit"]!.count
                let syncs=store.timings.snapshot["relay.sync"]?.count ?? 0
                var writes=0
                try DMLBatch.execute(batch,state:store,cancellation:.init(),lock:{_ in},write:{_ in
                    XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'"),[["4"]])
                    XCTAssertEqual(store.transactions,0)
                    writes+=1
                },completedGroup:{})
                XCTAssertEqual(writes,4)
                XCTAssertEqual(store.transactions,4)
                XCTAssertEqual(store.rows,4)
                XCTAssertEqual(store.applied,batch.last!.group.end)
                XCTAssertNil(store.pendingGTID)
                XCTAssertEqual(store.timings.snapshot["sqlite.commit"]!.count-commits,2)
                XCTAssertEqual(store.timings.snapshot["relay.sync"]!.count-syncs,1)
                XCTAssertEqual(try self.sqlite(path,"SELECT relay_end FROM groups ORDER BY sequence"),batch.map{[String($0.relayEnd)]})
                XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(*) FROM row_intents WHERE status='DONE'"),[["4"]])
            }
        }
    }
    func testBatchFailurePreservesWholeGroupPrefixAndPartialRowEvidence() throws {
        for profiling in [false,true] {
            try withBatchFixture(profiling:profiling) { store,input in
                var batch=input
                batch[1]=PreparedDMLGroup(group:input[1].group,mutations:input[1].mutations+input[1].mutations,relayEnd:input[1].relayEnd)
                var writes=0
                XCTAssertThrowsError(try DMLBatch.execute(batch,state:store,cancellation:.init(),lock:{_ in},write:{_ in
                    writes+=1
                    if writes == 3 { throw ApplyError("uncertain target failure") }
                },completedGroup:{})) { XCTAssertTrue(String(describing:$0).contains("uncertain target failure")) }
                XCTAssertEqual(writes,3)
                XCTAssertEqual(store.transactions,1)
                XCTAssertEqual(store.rows,1)
                XCTAssertEqual(store.applied,batch[0].group.end)
                XCTAssertEqual(store.pendingGTID,batch[1].id)
                let path=store.directory.appendingPathComponent("state.sqlite")
                XCTAssertEqual(try self.sqlite(path,"SELECT status FROM groups ORDER BY sequence"),[["APPLIED"],["PENDING"],["PENDING"],["PENDING"]])
                XCTAssertEqual(try self.sqlite(path,"SELECT status FROM row_intents ORDER BY gtid,ordinal"),[["DONE"],["DONE"],["PENDING"],["PENDING"],["PENDING"]])
                XCTAssertThrowsError(try store.stopped())
                try store.block("uncertain target failure")
            }
        }
    }
    func testBatchJournalFailuresNeverRetryWritesOrAdvancePartialMetadata() throws {
        for profiling in [false,true] {
            for preparation in [true,false] {
                try withBatchFixture(profiling:profiling) { store,batch in
                    let path=store.directory.appendingPathComponent("state.sqlite")
                    var db: OpaquePointer?
                    XCTAssertEqual(sqlite3_open(path.path,&db),SQLITE_OK)
                    defer { sqlite3_close(db) }
                    let trigger=preparation
                        ? "CREATE TRIGGER injected BEFORE INSERT ON row_intents WHEN NEW.gtid LIKE '%:12' BEGIN SELECT RAISE(ABORT,'prepare failure'); END"
                        : "CREATE TRIGGER injected BEFORE UPDATE OF applied_sequence ON state BEGIN SELECT RAISE(ABORT,'complete failure'); END"
                    XCTAssertEqual(sqlite3_exec(db,trigger,nil,nil,nil),SQLITE_OK)
                    let commits=store.timings.snapshot["sqlite.commit"]!.count
                    var writes=0
                    XCTAssertThrowsError(try DMLBatch.execute(batch,state:store,cancellation:.init(),lock:{_ in},write:{_ in writes+=1},completedGroup:{}))
                    XCTAssertEqual(writes,preparation ? 0 : 4)
                    XCTAssertEqual(store.transactions,0)
                    XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(*) FROM groups"),[[preparation ? "0" : "4"]])
                    XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(*) FROM row_intents WHERE status='DONE'"),[["0"]])
                    // Preparation aborts before COMMIT; completion failure has one
                    // successful prepare commit and no second completion attempt.
                    XCTAssertEqual(store.timings.snapshot["sqlite.commit"]!.count-commits,preparation ? 0 : 1)
                }
            }
        }
    }
    func testBatchRejectsNonPrefixAcknowledgmentsAndDuplicateGTIDs() throws {
        try withBatchFixture { store,batch in
            let duplicate=PreparedDMLGroup(group:batch[0].group,mutations:batch[0].mutations,relayEnd:batch[1].relayEnd)
            XCTAssertThrowsError(try store.beginBatch([batch[0],duplicate]))
            XCTAssertNil(store.pendingGTID)
            try store.beginBatch(batch)
            for counts in [[0,1,0,0],[2,0,0,0],[1,1]] {
                XCTAssertThrowsError(try store.finishBatch(acknowledgedRows:counts))
                XCTAssertEqual(store.transactions,0)
            }
            try store.finishBatch(acknowledgedRows:[0,0,0,0])
            XCTAssertEqual(try self.sqlite(store.directory.appendingPathComponent("state.sqlite"),"SELECT last_applied_at IS NULL FROM state"),[["1"]])
        }
    }
    func testPreparedBatchCannotResumeButCompletedBatchCan() throws {
        for complete in [false,true] {
            let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:parent) }
            let configuration=try config(parent.appendingPathComponent("state").path)
            do {
                let store=try StateStore(configuration:configuration)
                try store.bindTargetIdentity("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
                try store.running()
                try store.beginBatch(batchFixture(store))
                if complete { try store.finishBatch(acknowledgedRows:[1,1,1,1]); try store.stopped() }
            }
            if complete {
                let resumed=try StateStore(configuration:configuration,initialize:false)
                XCTAssertEqual(resumed.transactions,4)
                XCTAssertNil(resumed.pendingGTID)
            } else { XCTAssertThrowsError(try StateStore(configuration:configuration,initialize:false)) }
        }
    }
    func testBatchCollectionBoundsIdleFlushAndNoRetryAfterFailure() throws {
        try withBatchFixture { _,input in
            var policy=BatchPolicy(); policy.maximumTransactions=2
            var time=10.0, sizes:[Int]=[]
            let buffer=DMLBatch(policy:policy,uptime:{time}) { sizes.append($0.count) }
            try buffer.append(input[0]); XCTAssertTrue(sizes.isEmpty)
            try buffer.append(input[1]); XCTAssertEqual(sizes,[2])
            try buffer.append(input[2]); time+=0.026; try buffer.flushIfExpired()
            XCTAssertEqual(sizes,[2,1])
            try buffer.append(input[3]); try buffer.flush(); XCTAssertEqual(sizes,[2,1,1])
            var attempts=0
            let failed=DMLBatch(policy:policy) { _ in attempts+=1; throw ApplyError("failed batch") }
            try failed.append(input[0]); XCTAssertThrowsError(try failed.flush())
            XCTAssertThrowsError(try failed.flush()); XCTAssertThrowsError(try failed.append(input[1]))
            XCTAssertEqual(attempts,1)
        }
    }
    func testBatchFlushesAtRowByteAndTableBoundariesWithoutSplittingGroups() throws {
        try withBatchFixture { _,input in
            for limit in ["rows","bytes","table"] {
                var policy=BatchPolicy(), sizes:[Int]=[]
                if limit == "rows" { policy.maximumRows=1 }
                if limit == "bytes" { policy.maximumWireBytes=input[0].wireBytes+input[1].wireBytes-1 }
                let buffer=DMLBatch(policy:policy) { sizes.append($0.count) }
                var second=input[1]
                if limit == "table" {
                    let old=second.mutations[0]
                    let table=ApplyTable(database:"other",table:old.table.table,columns:old.table.columns,primaryKey:old.table.primaryKey)
                    second=PreparedDMLGroup(group:second.group,mutations:[Mutation(table:table,row:old.row,eventOffset:old.eventOffset,rowIndex:old.rowIndex)],relayEnd:second.relayEnd)
                }
                try buffer.append(input[0]); try buffer.append(second); try buffer.flush()
                XCTAssertEqual(sizes,[1,1],limit)
            }
            var policy=BatchPolicy(); policy.maximumRows=1
            var rows:[Int]=[]
            let buffer=DMLBatch(policy:policy) { rows.append($0[0].mutations.count) }
            try buffer.append(PreparedDMLGroup(group:input[0].group,mutations:input[0].mutations+input[0].mutations,relayEnd:input[0].relayEnd))
            XCTAssertEqual(rows,[2])
        }
    }
    func testBatchPolicyRejectsUnboundedSettings() throws {
        for json in ["{\"maximumTransactions\":0}","{\"maximumTransactions\":257}","{\"maximumRows\":0}","{\"maximumWireBytes\":0}","{\"maximumDelayMilliseconds\":1001}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(BatchPolicy.self,from:Data(json.utf8)).validate())
        }
        XCTAssertEqual(try config().batchPolicy.maximumTransactions,32)
    }
}
