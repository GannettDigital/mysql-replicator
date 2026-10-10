import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec
@testable import ReplicatorCapture

extension ResumeTests {
    private func recoveryFixture(completed: Int = 0, block: Bool = true, foreignKeys: Bool = false) throws -> (URL,ApplyConfiguration,[PreparedDMLGroup]) {
        let path=try directory(), c=try helper.config(path.path,profile:ReplicationProfile.mysql57To84InnoDB.rawValue)
        var table = try helper.tables()[0]
        if foreignKeys {
            table.foreignKeys = [
                ApplyForeignKey(name:"child_fk",database:table.database,table:"child",columns:["parent_id"],referencedDatabase:table.database,referencedTable:table.table,referencedColumns:table.primaryKeyColumns,onDelete:"CASCADE"),
                ApplyForeignKey(name:"grand_fk",database:table.database,table:"grandchild",columns:["child_id"],referencedDatabase:table.database,referencedTable:"child",referencedColumns:["id"],onDelete:"CASCADE")
            ]
        }
        var groups: [PreparedDMLGroup] = []
        do {
            let store=try StateStore(configuration:c)
            try store.bindTargetIdentity(target); try store.running()
            let binlog=try Data(contentsOf:helper.root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
            let size=(0..<4).reduce(UInt32(0)) { $0 | UInt32(binlog[4+9+$1]) << (8*$1) }
            let format=try BinlogDecoder().decode(Data(binlog[4..<4+Int(size)]),at:4,includeRaw:true)
            try store.append(.init(kind:"formatContext",file:"binlog.000003",observedPosition:String(format.nextPosition),event:format,rawBase64:nil))
            for group in try helper.groups() {
                try store.schema(table,event:group.events.first{$0.eventType == 19}!,coordinate:group.start)
                for event in group.events { try store.append(.init(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
                groups.append(.init(group:group,mutations:try DMLPlan.make(group,tables:[table]),relayEnd:store.relayLength))
            }
            try store.beginBatch(groups)
            if completed > 0 { try store.finishBatch(acknowledgedRows:groups.enumerated().map { $0.offset < completed ? $0.element.mutations.count : 0 }) }
            if block { try store.block("simulated uncertain COMMIT") }
        }
        return (path,c,groups)
    }
    func testUncertainCommitEvidenceIncludesIndirectCascadeTables() throws {
        let (_,configuration,_) = try recoveryFixture(foreignKeys:true)
        let report = try Recovery.inspect(configuration:configuration)
        XCTAssertEqual(report.pending.first?.foreignKeyRelationships.map(\.table),["child","grandchild"])
        let json = String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        XCTAssertTrue(json.contains("foreignKeyRelationships"))
        XCTAssertTrue(json.contains("implicit cascade row images are not present"))
    }
    func testRecoveryInspectsRowsAndRejectsActiveWriter() throws {
        let (_,c,groups)=try recoveryFixture()
        let report=try Recovery.inspect(configuration:c)
        XCTAssertEqual(report.pending.map(\.gtid),groups.map(\.id))
        XCTAssertEqual(report.pending.map{$0.rows.count},[1,1,1,1])
        XCTAssertEqual(report.pending[0].rows[0].afterKey,[.signed(3)])
        XCTAssertFalse(report.pending[0].expectations.isEmpty)
        XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.skip,gtids:groups[1].id,reason:"wrong order"))
        XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.retry,gtids:groups[0].id,reason:"incomplete batch"))
        XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.skip,gtids:groups[0].id,reason:" "))
        _ = try Recovery.resolve(configuration:c,action:.retry,gtids:helper.sid+":11-14",reason:"restored entire pending batch to source baseline")
        let writer=try StateStore(configuration:c,initialize:false)
        XCTAssertThrowsError(try Recovery.inspect(configuration:c))
        withExtendedLifetime(writer) {}
    }
    func testRecoveryResolvesPrefixAndAuditsSkipSeparatelyFromAppliedRows() throws {
        let (path,c,groups)=try recoveryFixture(completed:1)
        let r=try Recovery.resolve(configuration:c,action:.markApplied,gtids:groups[1].id,reason:"DBA verified committed rows")
        XCTAssertEqual(r.lifecycle,"BLOCKED")
        XCTAssertThrowsError(try StateStore(configuration:c,initialize:false))
        _ = try Recovery.resolve(configuration:c,action:.skip,gtids:groups[2].id,reason:"DBA reconciled this transaction")
        let final=try Recovery.resolve(configuration:c,action:.markApplied,gtids:groups[3].id,reason:"verified last transaction")
        XCTAssertEqual(final.lifecycle,"STOPPED")
        let store=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(store.gtids,helper.sid+":1-14")
        XCTAssertEqual(store.transactions,4); XCTAssertEqual(store.rows,3)
        XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"SELECT action FROM recovery_audit ORDER BY rowid"),[["mark-applied"],["skip"],["mark-applied"]])
    }
    func testRecoveryCrashTailPreservedAndRetryDoesNotAdvanceCheckpoint() throws {
        let (path,c,groups)=try recoveryFixture(completed:1,block:false)
        let relay=path.appendingPathComponent("relay.frames"), original=try Data(contentsOf:relay)
        let handle=try FileHandle(forWritingTo:relay); try handle.seekToEnd(); try handle.write(contentsOf:Data([1,2,3])); try handle.close()
        let before=try Recovery.inspect(configuration:c)
        XCTAssertEqual(before.lifecycle,"RUNNING"); XCTAssertEqual(before.unjournaledTailBytes,3)
        let result=try Recovery.resolve(configuration:c,action:.retry,gtids:helper.sid+":12-14",reason:"DBA restored all unresolved rows to initial images")
        XCTAssertEqual(result.lifecycle,"STOPPED")
        XCTAssertEqual(try Data(contentsOf:relay),original)
        let tails=try FileManager.default.contentsOfDirectory(at:path,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("recovery-tail-")}
        XCTAssertEqual(tails.count,1); XCTAssertEqual(try Data(contentsOf:tails[0]),Data([1,2,3]))
        let store=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(store.transactions,1); XCTAssertEqual(store.applied,groups[0].group.end)
        XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"SELECT json_array_length(evidence_json,'$.pending') FROM recovery_audit"),[["3"]])
    }
    func testRecoveryResolutionRollsBackAuditAndProgressTogether() throws {
        let (path,c,groups)=try recoveryFixture()
        try write(path,"CREATE TRIGGER reject_resolution BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'test failure'); END")
        XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.markApplied,gtids:groups[0].id,reason:"fault injection"))
        XCTAssertEqual(try Recovery.inspect(configuration:c).pending.count,4)
        XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"SELECT COUNT(*) FROM sqlite_master WHERE name='recovery_audit'"),[["0"]])
        try write(path,"DROP TRIGGER reject_resolution")
        XCTAssertNoThrow(try Recovery.resolve(configuration:c,action:.markApplied,gtids:groups[0].id,reason:"retry after SQLite failure"))
    }
    func testRecoveryRejectsDamagedRelayAndProfileMismatch() throws {
        let (path,c,_)=try recoveryFixture()
        XCTAssertThrowsError(try Recovery.inspect(configuration:helper.config(path.path)))
        let handle=try FileHandle(forUpdating:path.appendingPathComponent("relay.frames"))
        try handle.truncate(atOffset:20); try handle.close()
        XCTAssertThrowsError(try Recovery.inspect(configuration:c))
        XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.retry,gtids:helper.sid+":11-14",reason:"must not bypass missing evidence"))
    }
    func testRecoveryWithNoPendingIntentsPreservesCommittedHistory() throws {
        let (_,c,_)=try recoveryFixture(completed:4,block:false)
        XCTAssertEqual(try Recovery.inspect(configuration:c).pending.count,0)
        _ = try Recovery.resolve(configuration:c,action:.retry,gtids:"none",reason:"crashed after journal completion; no uncertain writes")
        let store=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(store.transactions,4); XCTAssertEqual(store.gtids,helper.sid+":1-14")
    }
    func testRecoveryRefusesJournalEvidenceMismatch() throws {
        for damage in ["DELETE FROM row_intents WHERE gtid=(SELECT active_gtid FROM state)",
                       "UPDATE groups SET end_position=CAST(end_position AS INTEGER)+1 WHERE gtid=(SELECT active_gtid FROM state)",
                       "UPDATE row_intents SET source_row='99' WHERE gtid=(SELECT active_gtid FROM state)"] {
            let (path,c,groups)=try recoveryFixture()
            try write(path,damage)
            XCTAssertThrowsError(try Recovery.inspect(configuration:c))
            XCTAssertThrowsError(try Recovery.resolve(configuration:c,action:.markApplied,gtids:groups[0].id,reason:"must not bless damaged evidence"))
            XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"SELECT transactions_applied FROM state"),[["0"]])
        }
    }
    func testRecoveryFoldsRepeatedChangesAndPrimaryKeyMoves() throws {
        let table=helper.tables()[0]
        func row(_ before: [DecodedValue]?, _ after: [DecodedValue]?) -> Recovery.Row {
            .init(ordinal:0,status:"PENDING",schemaID:"1",schema:table,sourceEventOffset:"1",sourceRow:0,operation:"update",beforeKey:before.map{[$0[0]]},afterKey:after.map{[$0[0]]},before:before,after:after)
        }
        let a: [DecodedValue] = [.signed(1),.text("a"),.unsigned(1)], b: [DecodedValue] = [.signed(1),.text("b"),.unsigned(2)]
        let c: [DecodedValue] = [.signed(2),.text("c"),.unsigned(3)]
        let folded=try Recovery.fold([row(a,b),row(b,c),row(c,nil)])
        XCTAssertEqual(folded.count,2); XCTAssertEqual(folded[0].initial,a); XCTAssertNil(folded[0].final)
        XCTAssertNil(folded[1].initial); XCTAssertNil(folded[1].final)
        XCTAssertFalse(folded.contains{$0.ambiguous})
        XCTAssertTrue(try Recovery.fold([row(a,b),row(a,c)])[0].ambiguous)
    }
}
