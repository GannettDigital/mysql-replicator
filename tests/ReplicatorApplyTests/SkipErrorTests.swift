import XCTest
import Foundation
import CSQLite
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ApplyTests {
    private var duplicate: ApplyError { .init("duplicate key",code:.duplicateKey,mysqlErrorNumber:1062,sqlState:"23000") }
    private func skipPolicy(_ codes: [String], audit: Bool = true) throws -> SkipErrorPolicy {
        try JSONDecoder().decode(SkipErrorPolicy.self,from:JSONSerialization.data(withJSONObject:["codes":codes,"recordSkippedTransactions":audit]))
    }
    func testSkipErrorPolicyRequiresExplicitKnownCodesAndReplay() throws {
        XCTAssertTrue(try config().skipErrorPolicy.codes.isEmpty)
        XCTAssertTrue(try config().skipErrorPolicy.recordSkippedTransactions)
        let c=try config(skipErrors:["codes":["mysql.1062"],"recordSkippedTransactions":false])
        XCTAssertThrowsError(try c.validate())
        XCTAssertNoThrow(try c.validate(offline:true))
        for codes in [["all"],["target.sql"],["mysql.1062","mysql.1062"]] {
            XCTAssertThrowsError(try config(skipErrors:["codes":codes]).validate(offline:true))
        }
        let policy=try skipPolicy(["mysql.1062","ddl.unsupported_statement"])
        XCTAssertNil(policy.match(ApplyError("duplicate key"),at:.rolledBack))
        XCTAssertNil(policy.match(duplicate,at:.beforeWrites))
        XCTAssertNotNil(policy.match(duplicate,at:.rolledBack))
        XCTAssertNil(policy.match(ApplyError("unsupported",code:.unsupportedDDL),at:.rolledBack))
        XCTAssertNil(policy.match(TargetConnectionFailure(description:"connection lost"),at:.rolledBack))
    }
    func testSkipErrorCodesComeFromParserAndPlanner() throws {
        let parser=DDLTests()
        for (sql,code) in [("ALTER TABLE items ENABLE KEYS",ApplyErrorCode.unsupportedAlter),
                           ("CREATE TABLE items(id INT PRIMARY KEY,v VECTOR)",.unsupportedColumnType),
                           ("ANALYZE TABLE items",.unsupportedDDL)] {
            XCTAssertThrowsError(try parser.parse(sql)) { XCTAssertEqual(($0 as? ApplyError)?.code,code) }
        }
        let groups=try groups()
        let combined=CompleteTransaction(start:groups[0].start,end:groups[1].end,gtid:groups[0].gtid,anonymous:false,outcome:.committed,events:groups[0].events+groups[1].events)
        XCTAssertThrowsError(try DMLPlan.make(combined,tables:tables())) {
            XCTAssertEqual(($0 as? ApplyError)?.code,.multipleStatements)
        }
    }
    func testSkipErrorInnoDBRollbackThenContinuesAndDoesNotCountSkippedRows() throws {
        for audit in [false,true] {
            let settings: [String:Any]=["codes":["mysql.1062"],"recordSkippedTransactions":audit]
            try withBatchFixture(profile:ReplicationProfile.mysql57To84InnoDB.rawValue,skipErrors:settings) { store,batch in
                try store.beginBatch(batch)
                var writes=0,commits=0,rollbacks=0
                let result=InnoDBExecution.run(batch,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1048576,
                    skipErrors:try skipPolicy(["mysql.1062"],audit:audit),begin:{},commit:{ commits+=1 },rollback:{ rollbacks+=1 },
                    write:{ _ in writes+=1;if writes == 2 { throw self.duplicate } },insert:{_ in XCTFail("unexpected coalescing")},resetTrace:{},trace:{.init(phase:.possiblyExecuted)})
                XCTAssertNil(result.failure);XCTAssertEqual(result.acknowledged,[1,0,1,1]);XCTAssertEqual(Set(result.skipped.keys),[1])
                XCTAssertEqual(commits,3);XCTAssertEqual(rollbacks,1)
                try result.record(in:store)
                XCTAssertEqual(store.transactions,4);XCTAssertEqual(store.rows,3)
                XCTAssertEqual(store.skippedTransactionsByCode,["mysql.1062":1]);XCTAssertNil(store.pendingGTID)
                XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-14")
                let db=store.directory.appendingPathComponent("state.sqlite")
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM groups"),[["3"]])
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM row_intents"),[["3"]])
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM error_skips"),[[audit ? "1" : "0"]])
                if audit {
                    let json=try sqlite(db,"SELECT diagnostic_json FROM error_skips")[0][0]
                    let error=try JSONDecoder().decode(SkippedApplyError.self,from:Data(json.utf8))
                    XCTAssertEqual(error.code,.duplicateKey);XCTAssertEqual(error.mysqlErrorNumber,1062)
                    XCTAssertEqual(error.sqlState,"23000");XCTAssertEqual(error.outcome,"rolledBack")
                }
            }
        }
    }
    func testSkipErrorInnoDBNeverSkipsCommitOrUnconfirmedRollback() throws {
        for failCommit in [false,true] {
            try withBatchFixture { _,batch in
                let result=InnoDBExecution.run(batch,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1048576,
                    skipErrors:try skipPolicy(["mysql.1062"]),begin:{},commit:{ throw self.duplicate },
                    rollback:{ throw ApplyError("rollback failed") },write:{_ in if !failCommit { throw self.duplicate } },insert:{_ in},resetTrace:{},trace:{.init(phase:.possiblyExecuted)})
                XCTAssertNotNil(result.failure);XCTAssertTrue(result.skipped.isEmpty)
                XCTAssertEqual(result.acknowledged,[0,0,0,0])
                XCTAssertEqual(result.diagnostic?.transactionOutcome,failCommit ? "commitUncertain" : "rollbackUnconfirmed")
            }
        }
    }
    func testSkipErrorMyISAMDuplicateStillBlocks() throws {
        try withBatchFixture(skipErrors:["codes":["mysql.1062"]]) { store,batch in
            try store.beginBatch(batch)
            let result=DMLExecution.run(batch,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1048576,
                lock:{_ in},write:{_ in throw self.duplicate},insert:{_ in throw self.duplicate},completedGroup:{})
            XCTAssertTrue(result.skipped.isEmpty);XCTAssertThrowsError(try result.record(in:store))
            XCTAssertEqual(store.transactions,0);XCTAssertEqual(store.pendingGTID,batch[0].id)
        }
    }
    func testSkipErrorLaterFailurePreservesSkippedAndCommittedPrefixOnly() throws {
        try withBatchFixture(profile:ReplicationProfile.mysql57To84InnoDB.rawValue,skipErrors:["codes":["mysql.1062"]]) { store,batch in
            try store.beginBatch(batch)
            var writes=0
            let result=InnoDBExecution.run(batch,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1048576,
                skipErrors:try skipPolicy(["mysql.1062"]),begin:{},commit:{},rollback:{},write:{_ in
                    writes+=1;if writes == 1 { throw self.duplicate };if writes == 3 { throw ApplyError("unlisted failure") }
                },insert:{_ in},resetTrace:{},trace:{.init(phase:.possiblyExecuted)})
            XCTAssertThrowsError(try result.record(in:store))
            XCTAssertEqual(store.transactions,2);XCTAssertEqual(store.rows,1)
            XCTAssertEqual(store.pendingGTID,batch[2].id);XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-12")
            XCTAssertEqual(result.diagnostic?.rows.first?.disposition,"skippedRolledBack")
        }
    }
    func testSkipErrorWholeMultiRowTransactionRollsBackEarlierWrites() throws {
        try withBatchFixture { _,batch in
            let g=batch[0],combined=PreparedDMLGroup(group:g.group,mutations:g.mutations+g.mutations,relayEnd:g.relayEnd)
            var provisional=0,rollbacks=0
            let result=InnoDBExecution.run([combined],cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1048576,
                skipErrors:try skipPolicy(["mysql.1062"]),begin:{},commit:{ XCTFail("must not commit partial transaction") },
                rollback:{provisional=0;rollbacks+=1},write:{_ in provisional+=1;if provisional == 2 {throw self.duplicate}},
                insert:{_ in},resetTrace:{},trace:{.init(phase:.possiblyExecuted)})
            XCTAssertNil(result.failure);XCTAssertEqual(result.acknowledged,[0]);XCTAssertEqual(result.skipped.count,1)
            XCTAssertEqual(provisional,0);XCTAssertEqual(rollbacks,1)
        }
    }
    func testSkipErrorUnauditedRunKeepsConstantJournalRowsAndResumes() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:parent)}
        let c=try config(parent.appendingPathComponent("state").path,skipErrors:["codes":["ddl.unsupported_statement"],"recordSkippedTransactions":false])
        let failure=try XCTUnwrap(c.skipErrorPolicy.match(ApplyError("unsupported",code:.unsupportedDDL),at:.beforeWrites))
        let template=try groups()[0]
        do {
            let store=try StateStore(configuration:c)
            try store.bindTargetIdentity("11111111-1111-1111-1111-111111111111");try store.running()
            for n in 11...2010 {
                let group=CompleteTransaction(start:.init(file:template.start.file,position:UInt64(n*100)),end:.init(file:template.start.file,position:UInt64(n*100+99)),gtid:.init(sid:sid,sequence:String(n),flags:1),anonymous:false,outcome:.statement,events:template.events)
                for event in group.events { try store.append(.init(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
                try store.begin(group);try store.skipUnwritten(group,error:failure)
            }
            let db=store.directory.appendingPathComponent("state.sqlite")
            for table in ["groups","row_intents","error_skips"] { XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM \(table)"),[["0"]]) }
            XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM snapshots"),[["1"]])
            XCTAssertEqual(try sqlite(db,"SELECT * FROM error_skip_counts"),[["ddl.unsupported_statement","2000"]])
            XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-2010")
            try store.stopped()
        }
        let reopened=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(reopened.transactions,2000);XCTAssertEqual(reopened.rows,0)
        XCTAssertEqual(reopened.gtids,sid+":1-2010")
        XCTAssertEqual(reopened.skippedTransactionsByCode,["ddl.unsupported_statement":2000])
    }
    func testSkipErrorCheckpointFailureRollsBackAuditAndCoverage() throws {
        for audit in [false,true] {
            try withBatchFixture(profile:ReplicationProfile.mysql57To84InnoDB.rawValue,skipErrors:["codes":["mysql.1062"],"recordSkippedTransactions":audit]) { store,batch in
                try store.beginBatch(batch)
                let db=store.directory.appendingPathComponent("state.sqlite")
                var handle:OpaquePointer?
                XCTAssertEqual(sqlite3_open(db.path,&handle),SQLITE_OK);defer {sqlite3_close(handle)}
                XCTAssertEqual(sqlite3_exec(handle,"CREATE TRIGGER fail_skip BEFORE UPDATE OF applied_sequence ON state BEGIN SELECT RAISE(ABORT,'fault'); END",nil,nil,nil),SQLITE_OK)
                let skipped=try XCTUnwrap(skipPolicy(["mysql.1062"]).match(duplicate,at:.rolledBack))
                XCTAssertThrowsError(try store.finishBatch(acknowledgedRows:[0,0,0,0],skipped:[0:skipped]))
                XCTAssertEqual(store.transactions,0);XCTAssertTrue(store.skippedTransactionsByCode.isEmpty)
                XCTAssertEqual(try store.durableAppliedGTIDs(),sid+":1-10")
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM groups WHERE status='PENDING'"),[["4"]])
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM error_skip_counts"),[["0"]])
                XCTAssertEqual(try sqlite(db,"SELECT COUNT(*) FROM error_skips"),[["0"]])
            }
        }
    }
}
