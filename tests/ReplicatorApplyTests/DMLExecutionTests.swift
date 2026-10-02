import XCTest
import ReplicatorCapture
import ReplicatorCodec
@testable import ReplicatorApply

extension ApplyTests {
    private func inserts(_ input: [PreparedDMLGroup]) -> [PreparedDMLGroup] {
        input.map { PreparedDMLGroup(group:$0.group,mutations:input[0].mutations,relayEnd:$0.relayEnd) }
    }
    func testCombinedInsertPreparesAllIntentsAndKeepsSourceIdentities() throws {
        try withBatchFixture { state,input in
            let batch = inserts(input), path = state.directory.appendingPathComponent("state.sqlite")
            var calls = 0
            try DMLBatch.execute(batch,state:state,cancellation:.init(),maximumInsertRows:32,
                lock:{ _ in },write:{ _ in XCTFail("expected combined INSERT") },insert:{ rows in
                    calls += 1
                    XCTAssertEqual(rows.count,4)
                    XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'"),[["4"]])
                    XCTAssertEqual(state.transactions,0)
                },completedGroup:{})
            XCTAssertEqual(calls,1)
            XCTAssertEqual(state.transactions,4)
            XCTAssertEqual(state.rows,4)
            XCTAssertEqual(state.applied,batch.last!.group.end)
            XCTAssertEqual(try self.sqlite(path,"SELECT COUNT(DISTINCT gtid) FROM groups WHERE status='APPLIED'"),[["4"]])
        }
    }
    func testFailedCombinedInsertLeavesEntireChunkUncertainWithoutRetry() throws {
        try withBatchFixture { state,input in
            let batch = inserts(input), path = state.directory.appendingPathComponent("state.sqlite")
            var calls = 0
            XCTAssertThrowsError(try DMLBatch.execute(batch,state:state,cancellation:.init(),maximumInsertRows:2,
                lock:{ _ in },write:{ _ in XCTFail("unexpected single INSERT") },insert:{ rows in
                    calls += 1
                    if calls == 2 { throw ApplyError("partial MyISAM write / lost response") }
                },completedGroup:{}))
            XCTAssertEqual(calls,2)
            XCTAssertEqual(state.transactions,2)
            XCTAssertEqual(state.pendingGTID,batch[2].id)
            XCTAssertEqual(try self.sqlite(path,"SELECT status FROM row_intents ORDER BY gtid,ordinal"),[["DONE"],["DONE"],["PENDING"],["PENDING"]])
        }
    }
    func testInsertChunksRespectTableOperationByteAndGroupBoundaries() throws {
        try withBatchFixture { _,input in
            let batch = inserts(input), row = batch[0].mutations[0]
            var calls: [Int] = []
            let outcome = DMLExecution.run(batch,cancellation:.init(),maximumInsertRows:32,
                maximumInsertBytes:2*DMLExecution.insertBytes(row),lock:{ _ in },write:{ _ in calls.append(1) },
                insert:{ calls.append($0.count) },completedGroup:{})
            XCTAssertNil(outcome.failure); XCTAssertEqual(calls,[2,2])
            let other = ApplyTable(database:"other",table:row.table.table,columns:row.table.columns,primaryKey:row.table.primaryKey)
            let changed = PreparedDMLGroup(group:batch[1].group,
                mutations:[Mutation(table:other,row:row.row,eventOffset:row.eventOffset,rowIndex:row.rowIndex)],relayEnd:batch[1].relayEnd)
            calls=[]
            let split = DMLExecution.run([batch[0],changed,input[2],batch[3]],cancellation:.init(),maximumInsertRows:32,
                maximumInsertBytes:1024*1024,lock:{ _ in },write:{ _ in calls.append(1) },
                insert:{ calls.append($0.count) },completedGroup:{})
            XCTAssertNil(split.failure); XCTAssertEqual(calls,[1,1,1,1])
            // A large source group can use multiple SQL chunks but cannot
            // release/reacquire its table lock between those chunks.
            let large = PreparedDMLGroup(group:batch[0].group,mutations:Array(repeating:row,count:5),relayEnd:batch[0].relayEnd)
            calls=[]; var locks=0, completed=0
            let result = DMLExecution.run([large,batch[1]],cancellation:.init(),maximumInsertRows:2,
                maximumInsertBytes:1024*1024,lock:{ _ in locks += 1 },write:{ _ in calls.append(1) },
                insert:{ calls.append($0.count) },completedGroup:{ completed += 1 })
            XCTAssertNil(result.failure); XCTAssertEqual(calls,[2,2,1,1])
            XCTAssertEqual(locks,2); XCTAssertEqual(completed,2)
        }
    }
    func testExecutionCancellationAndLockFailureRetainKnownAcknowledgments() throws {
        try withBatchFixture { _,input in
            let batch = inserts(input), stop = CaptureCancellation()
            let outcome = DMLExecution.run(batch,cancellation:stop,maximumInsertRows:2,
                maximumInsertBytes:1024*1024,lock:{ _ in },write:{ _ in XCTFail() },
                insert:{ _ in stop.cancel() },completedGroup:{})
            XCTAssertNotNil(outcome.failure); XCTAssertEqual(outcome.acknowledged,[1,1,0,0])
            let releaseFailure = DMLExecution.run(batch,cancellation:.init(),maximumInsertRows:4,
                maximumInsertBytes:1024*1024,lock:{ _ in },write:{ _ in XCTFail() },insert:{ _ in },
                completedGroup:{ throw ApplyError("unlock failed") })
            XCTAssertNotNil(releaseFailure.failure); XCTAssertEqual(releaseFailure.acknowledged,[1,1,1,1])
        }
    }
    func testTargetWorkerOverlapsCoordinatorAndJoinsBeforeResultRead() {
        let executor = DMLExecutor(), entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        executor.start {
            entered.signal(); release.wait()
            return DMLExecution.Outcome(acknowledged:[1],failure:nil)
        }
        XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
        XCTAssertTrue(executor.active); XCTAssertFalse(executor.ready)
        // Coordinator work can proceed while SQL is in flight.
        var prepared = 0; prepared += 1
        release.signal()
        XCTAssertEqual(executor.join()?.acknowledged,[prepared])
        XCTAssertFalse(executor.active); XCTAssertNil(executor.join())
        executor.start { DMLExecution.Outcome(acknowledged:[0],failure:ApplyError("target failed")) }
        XCTAssertNotNil(executor.join()?.failure)
    }
    func testCollectionCanCrossTablesWithoutReordering() throws {
        try withBatchFixture { _,input in
            let row = input[1].mutations[0]
            let other = ApplyTable(database:"other",table:row.table.table,columns:row.table.columns,primaryKey:row.table.primaryKey)
            let second = PreparedDMLGroup(group:input[1].group,
                mutations:[Mutation(table:other,row:row.row,eventOffset:row.eventOffset,rowIndex:row.rowIndex)],relayEnd:input[1].relayEnd)
            var batches: [[String]] = []
            let buffer = DMLBatch(policy:BatchPolicy()) { batches.append($0.map(\.id)) }
            try buffer.append(input[0]); try buffer.append(second)
            XCTAssertTrue(batches.isEmpty)
            try buffer.flush(); XCTAssertEqual(batches,[[input[0].id,second.id]])
        }
    }
    func testInsertSQLUsesOnlyPlaceholdersAndBoundedPolicy() throws {
        let plan = try DMLSQLPlan(tables()[0])
        XCTAssertEqual(plan.insertSQL(rows:1),plan.insert)
        XCTAssertEqual(plan.insertSQL(rows:4).filter { $0 == "?" }.count,4*tables()[0].columns.count)
        for json in ["{\"maximumInsertRows\":0}","{\"maximumInsertRows\":129}","{\"maximumInsertBytes\":1}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(BatchPolicy.self,from:Data(json.utf8)).validate())
        }
    }
}
