import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture
@testable import ReplicatorCodec

extension ApplyTests {
    func testMySQL57MyISAMCombinesLegacyCaptureWithNontransactionalTarget() throws {
        let profile=ReplicationProfile.mysql57To57MyISAM
        XCTAssertTrue(profile.sourceContract.requiresHistoricalSchema)
        XCTAssertEqual(profile.targetContract.engine,"MyISAM")
        XCTAssertFalse(profile.transactional)
        let c=try config(profile:profile.rawValue)
        XCTAssertNoThrow(try c.validate())
        let positional=try config(profile:profile.rawValue,mode:"file-position")
        XCTAssertThrowsError(try positional.validate()) {
            XCTAssertTrue(String(describing:$0).contains("MySQL 5.7 source profiles require GTID"))
        }
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let path=parent.appendingPathComponent("state").path
        let selected=try config(path,profile:profile.rawValue)
        do {
            let store=try StateStore(configuration:selected)
            try store.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
            try store.running(); try store.stopped()
        }
        XCTAssertNoThrow(try StateStore(configuration:selected,initialize:false))
        for other in [ReplicationProfile.mysql84To57MyISAM,.mysql57To84InnoDB] {
            XCTAssertThrowsError(try StateStore(configuration:config(path,profile:other.rawValue),initialize:false)) {
                XCTAssertTrue(String(describing:$0).contains("profile differs"))
            }
        }
    }

    func testReplicationProfileDefaultsAndStateBinding() throws {
        XCTAssertEqual(try config().replicationProfile,.mysql84To57MyISAM)
        XCTAssertThrowsError(try config(profile:"unqualified-profile"))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        let path = parent.appendingPathComponent("state").path
        let reverse = try config(path,profile:ReplicationProfile.mysql57To84InnoDB.rawValue)
        try reverse.validate()
        do {
            let state = try StateStore(configuration:reverse)
            try state.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
            try state.running(); try state.stopped()
        }
        XCTAssertThrowsError(try StateStore(configuration:config(path),initialize:false)) {
            XCTAssertTrue(String(describing:$0).contains("profile differs"))
        }
        XCTAssertNoThrow(try StateStore(configuration:reverse,initialize:false))
        XCTAssertThrowsError(try config(collations:["utf8mb4_0900_ai_ci":"utf8mb4_unicode_ci"],profile:ReplicationProfile.mysql57To84InnoDB.rawValue).validate())
    }

    func testSchemaRequestCannotDeadlockOnConsumerFailure() throws {
        let event = try groups()[0].events.first{$0.eventType == 19}!
        let pipeline = ApplyPipeline()
        XCTAssertThrowsError(try pipeline.run(cancellation:.init(),producerTimings:.init(),produce:{ stop,send in
            let request = ApplySchemaRequest(event)
            try send(.schema(request))
            _ = try request.wait(cancellation:stop)
        },consume:{ _ in throw ApplyError("schema rejected") },onWait:{},timings:.init())) {
            XCTAssertEqual(String(describing:$0),"schema rejected")
        }
        let request = ApplySchemaRequest(event)
        request.complete(.success([.signed,.utf8]))
        XCTAssertEqual(try request.wait(cancellation:.init()),[.signed,.utf8])
    }

    func testInnoDBAutocommitKeepsSourceTransactionsSeparate() throws {
        try withBatchFixture { store,groups in
            try store.beginBatch(groups)
            var operations: [String] = []
            let result = InnoDBExecution.run(groups,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1024*1024,
                begin:{ operations.append("begin") },commit:{ operations.append("commit") },rollback:{ XCTFail("unexpected rollback") },
                write:{ _ in operations.append("write") },insert:{ _ in XCTFail("cross-transaction INSERT") },resetTrace:{},trace:{ .init() })
            XCTAssertNil(result.failure)
            XCTAssertEqual(operations,Array(repeating:"write",count:4))
            try result.record(in:store)
            XCTAssertEqual(store.transactions,4)
        }
    }

    func testInnoDBPreparationPrecedesBeginAndFailureLeavesTargetUnstarted() throws {
        try withBatchFixture { _,groups in
            var operations: [String] = []
            let outcome=InnoDBExecution.run(Array(groups.prefix(1)),cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024,
                prepare:{ _ in operations.append("prepare"); throw ApplyError("schema changed") },
                begin:{ operations.append("begin") },commit:{ operations.append("commit") },rollback:{ operations.append("rollback") },
                write:{ _ in operations.append("write") },insert:{ _ in operations.append("insert") },resetTrace:{},trace:{ .init() })
            XCTAssertEqual(operations,["prepare"])
            XCTAssertEqual(outcome.acknowledged,[0])
            XCTAssertEqual(outcome.diagnostic?.transactionOutcome,"notStarted")
        }
    }
    func testInnoDBCommitLossDoesNotAcknowledgeOrRollbackUncertainTransaction() throws {
        try withBatchFixture { store,input in
            let groups=input.map { PreparedDMLGroup(group:$0.group,mutations:$0.mutations+$0.mutations,relayEnd:$0.relayEnd) }
            try store.beginBatch(groups)
            var commits = 0, writes = 0
            let result = InnoDBExecution.run(groups,cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                begin:{},commit:{ commits += 1; if commits == 2 { throw TargetConnectionFailure(description:"lost COMMIT response") } },
                rollback:{ XCTFail("ROLLBACK cannot disprove a prior COMMIT") },
                write:{ _ in writes += 1 },insert:{ _ in },resetTrace:{},trace:{ .init(phase:.possiblyExecuted,sql:"COMMIT") })
            XCTAssertEqual(result.acknowledged,[2,0,0,0])
            XCTAssertEqual(result.diagnostic?.transactionOutcome,"commitUncertain")
            XCTAssertEqual(writes,4)
            XCTAssertThrowsError(try result.record(in:store))
            XCTAssertEqual(store.transactions,1)
            XCTAssertEqual(store.pendingGTID,groups[1].id)
        }
    }

    func testInnoDBAutocommitLostResponseRetainsUncertainIntent() throws {
        try withBatchFixture { store,groups in
            try store.beginBatch(groups)
            var writes=0
            let result=InnoDBExecution.run(groups,cancellation:.init(),maximumInsertRows:32,maximumInsertBytes:1024*1024,
                begin:{ XCTFail("unexpected BEGIN") },commit:{ XCTFail("unexpected COMMIT") },
                rollback:{ XCTFail("ROLLBACK cannot disprove an autocommit write") },
                write:{ _ in writes+=1; if writes == 2 { throw TargetConnectionFailure(description:"lost write response") } },
                insert:{ _ in XCTFail("cross-transaction INSERT") },resetTrace:{},trace:{ .init(phase:.possiblyExecuted,sql:"INSERT") })
            XCTAssertEqual(result.acknowledged,[1,0,0,0])
            XCTAssertEqual(result.diagnostic?.transactionOutcome,"commitUncertain")
            XCTAssertEqual(writes,2)
            XCTAssertThrowsError(try result.record(in:store))
            XCTAssertEqual(store.transactions,1)
            XCTAssertEqual(store.pendingGTID,groups[1].id)
        }
    }

    func testInnoDBMultipleStatementsRetainExplicitTransactionBoundaries() throws {
        try withBatchFixture { store,input in
            let groups=input.map { PreparedDMLGroup(group:$0.group,mutations:$0.mutations+$0.mutations,relayEnd:$0.relayEnd) }
            try store.beginBatch(groups)
            var operations: [String]=[]
            let result=InnoDBExecution.run(groups,cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                begin:{ operations.append("begin") },commit:{ operations.append("commit") },rollback:{ XCTFail("unexpected rollback") },
                write:{ _ in operations.append("write") },insert:{ _ in XCTFail("unexpected chunk") },resetTrace:{},trace:{ .init() })
            XCTAssertNil(result.failure)
            XCTAssertEqual(operations,Array(repeating:["begin","write","write","commit"],count:4).flatMap{$0})
            XCTAssertEqual(result.acknowledged,[2,2,2,2])
            try result.record(in:store)
            XCTAssertEqual(store.transactions,4); XCTAssertEqual(store.rows,8)
        }
    }

    func testInnoDBRollsBackAllRowsAndRetainsIntentOnFailure() throws {
        for rollbackSucceeds in [true,false] {
            try withBatchFixture { store,input in
                let group = PreparedDMLGroup(group:input[0].group,mutations:input.flatMap(\.mutations),relayEnd:input.last!.relayEnd)
                try store.beginBatch([group])
                var writes = 0, rollbacks = 0
                let result = InnoDBExecution.run([group],cancellation:.init(),maximumInsertRows:1,maximumInsertBytes:1024*1024,
                    begin:{},commit:{ XCTFail("failed transaction must not commit") },
                    rollback:{ rollbacks += 1; if !rollbackSucceeds { throw ApplyError("connection lost") } },
                    write:{ _ in writes += 1; if writes == 2 { throw ApplyError("duplicate key") } },insert:{ _ in },
                    resetTrace:{},trace:{ .init(phase:.acknowledged) })
                XCTAssertEqual(result.acknowledged,[0]); XCTAssertEqual(rollbacks,1)
                XCTAssertEqual(result.diagnostic?.transactionOutcome,rollbackSucceeds ? "rolledBack" : "rollbackUnconfirmed")
                XCTAssertThrowsError(try result.record(in:store))
                XCTAssertEqual(store.transactions,0)
                XCTAssertEqual(try self.sqlite(store.directory.appendingPathComponent("state.sqlite"),"SELECT DISTINCT status FROM row_intents"),[["PENDING"]])
            }
        }
    }

    func testInnoDBPlanningAllowsMultipleStatementsWithoutWeakeningMyISAM() throws {
        let groups = try groups()
        let combined = CompleteTransaction(start:groups[0].start,end:groups[1].end,gtid:groups[0].gtid,
            anonymous:false,outcome:.committed,events:groups[0].events+groups[1].events)
        let table = tables()[0], plans = [table.identity:try DMLTablePlan(table)]
        XCTAssertThrowsError(try DMLPlan.make(combined,tables:plans))
        XCTAssertEqual(try DMLPlan.make(combined,tables:plans,transactional:true).count,2)
    }

    func testLegacyMetadataUsesSchemaOnlyForMissingFields() throws {
        let plan = try DMLTablePlan(tables()[0])
        let wire = [WireColumn(interpretation:nil,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:false,name:nil),
                    WireColumn(interpretation:nil,type:15,maximumBytes:400,nullable:false,collation:0,primaryKey:false,name:nil,metadata:Data([144,1])),
                    WireColumn(interpretation:nil,type:8,maximumBytes:0,nullable:false,collation:0,primaryKey:false,name:nil)]
        XCTAssertThrowsError(try plan.validate(wire:wire))
        XCTAssertNoThrow(try plan.validate(wire:wire,legacyMetadata:true))
        var conflict = wire
        conflict[2] = WireColumn(interpretation:.signed,type:8,maximumBytes:0,nullable:false,collation:0,primaryKey:false,name:nil)
        XCTAssertThrowsError(try plan.validate(wire:conflict,legacyMetadata:true))
        conflict = wire
        conflict[1] = WireColumn(interpretation:nil,type:15,maximumBytes:200,nullable:false,collation:0,primaryKey:false,name:nil)
        XCTAssertThrowsError(try plan.validate(wire:conflict,legacyMetadata:true))
    }
}

extension ResumeTests {
    func testFormat8CheckpointMigratesOnlyAsMyISAM() throws {
        let path = try directory(), c = try config(path.path)
        do {
            let store = try StateStore(configuration:c)
            try store.bindTargetIdentity(target); try store.running()
            try apply(helper.groups()[0],to:store); try store.stopped()
        }
        try write(path,"DROP TABLE replication_profile; PRAGMA user_version=8")
        let db = path.appendingPathComponent("state.sqlite")
        let before = try helper.sqlite(db,"SELECT * FROM state")
        XCTAssertThrowsError(try StateStore(configuration:helper.config(path.path,profile:ReplicationProfile.mysql57To84InnoDB.rawValue),initialize:false))
        XCTAssertEqual(try helper.sqlite(db,"PRAGMA user_version"),[["8"]])
        do { let store = try StateStore(configuration:c,initialize:false); XCTAssertEqual(store.transactions,1) }
        XCTAssertEqual(try helper.sqlite(db,"PRAGMA user_version"),[["9"]])
        XCTAssertEqual(try helper.sqlite(db,"SELECT * FROM state"),before)
        XCTAssertEqual(try helper.sqlite(db,"SELECT profile FROM replication_profile"),[[ReplicationProfile.mysql84To57MyISAM.rawValue]])
    }
}
