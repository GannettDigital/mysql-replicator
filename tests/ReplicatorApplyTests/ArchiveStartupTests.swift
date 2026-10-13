import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCapture

final class ArchiveStartupTests: XCTestCase {
    func testReplayUsesSavedGTIDsAndCanStopValidationWithoutTargetAccess() throws {
        #if os(Linux)
        let helper=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helper=ApplyTests()
        #endif
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let c=try helper.config(root.appendingPathComponent("state").path)
        do {
            let state=try StateStore(configuration:c)
            try state.bindTargetIdentity("00000000-0000-0000-0000-000000000002")
            let group=try helper.groups()[0]
            try state.schema(helper.tables()[0],event:group.events.first(where:{$0.eventType == 19})!,coordinate:group.start)
            try state.running();try state.begin(group)
            try state.intent(0,DMLPlan.make(group,tables:helper.tables())[0])
            try state.rowDone(0);try state.complete(group,rowCount:1);try state.stopped()
        }
        let directory=root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        let fixture=try Data(contentsOf:helper.root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
        let formatLength=Int(ArchiveIO.read(Data(fixture[4..<23]),at:9,as:UInt32.self))
        let previousOffset=4+formatLength
        let previousLength=Int(ArchiveIO.read(Data(fixture[previousOffset..<previousOffset+19]),at:9,as:UInt32.self))
        var preamble=Data(fixture.prefix(previousOffset+previousLength))
        // Require GTID 11. It is in SQLite, but not in the configured 1-10 baseline.
        var upper=UInt64(12).littleEndian
        withUnsafeBytes(of:&upper) { preamble.replaceSubrange(preamble.count-12..<preamble.count-4,with:$0) }
        var crc=ArchiveIO.crc32(Data(preamble[previousOffset..<preamble.count-4])).littleEndian
        withUnsafeBytes(of:&crc) { preamble.replaceSubrange(preamble.count-4..<preamble.count,with:$0) }
        try preamble.write(to:directory.appendingPathComponent("binlog.000004"))
        let archiveConfig=try JSONDecoder().decode(ArchiveConfiguration.self,from:JSONSerialization.data(withJSONObject:["directory":directory.path]))
        let drain=CaptureCancellation()
        var phases:[String]=[]
        let archive=try ArchiveReplay(configuration:archiveConfig,source:c.source,contract:.mysql84,progress:{ progress in
            phases.append(progress.phase)
            if progress.phase == "validation" { drain.cancel() }
        })
        let result=try ApplyRun.run(configuration:c,sourcePassword:"",targetPassword:"",drain:drain,archive:archive)
        XCTAssertEqual(result.lifecycle,"STOPPED")
        XCTAssertEqual(result.appliedGTIDSet,helper.sid+":1-11")
        XCTAssertEqual(result.stopReason,"drainRequested")
        XCTAssertTrue(phases.contains("validation"))
        XCTAssertFalse(phases.contains("validated"))
        // The saved state remains suitable for a later resume.
        let reopened=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(reopened.gtids,helper.sid+":1-11")
    }
}
