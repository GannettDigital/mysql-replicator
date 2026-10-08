import XCTest
import Foundation
@testable import ReplicatorApply
import ReplicatorCapture

final class RunControlTests: XCTestCase {
    func summary(_ lifecycle:String) -> ApplySummary {
        ApplySummary(lifecycle:lifecycle,transactionsApplied:2,rowsApplied:2,ddlApplied:0,appliedPosition:nil,
            appliedGTIDSet:"00000000-0000-0000-0000-000000000001:1-2",pendingGTID:nil,stateDirectory:"test",
            stageTimings:nil,pipeline:nil,sourceReconnectEnabled:false,sourceReconnectAttempts:0,sourceReconnectReason:nil,
            targetReconnectEnabled:false,targetReconnectAttempts:0,targetReconnectReason:nil,targetFailure:nil,drainRequested:lifecycle == "STOPPED")
    }
    func testLocalCommandsAcknowledgeCoordinatorAndCleanUpSocket() throws {
        let directory=URL(fileURLWithPath:"/tmp/repl-ctl-"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let drain=CaptureCancellation(),limits=try StopConditions(transactions:10,gtids:nil)
        let control=RunControl(limits:limits,drain:drain) { try StopConditions(transactions:20,gtids:nil) }
        try control.start(directory:directory);control.publish(summary("RUNNING"))
        func reply(_ command:String) throws -> [String:Any] {
            try JSONSerialization.jsonObject(with:ControlClient.request(.init(command:command,timeoutSeconds:5),stateDirectory:directory.path)) as! [String:Any]
        }
        let status=try reply("status")
        XCTAssertEqual(status["configurationGeneration"] as? Int,1)
        XCTAssertEqual((status["progress"] as? [String:Any])?["transactionsApplied"] as? Int,2)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("control.sock").path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let reloaded=expectation(description:"reload reply")
        DispatchQueue.global().async {
            do {
                let r=try reply("reload")
                XCTAssertEqual(r["ok"] as? Bool,true);XCTAssertEqual(r["configurationGeneration"] as? Int,2)
            } catch { XCTFail(String(describing:error)) }
            reloaded.fulfill()
        }
        let until=Date().addingTimeInterval(3)
        while !control.reloadRequested && Date() < until { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(control.reloadRequested)
        control.acknowledge(.success(try control.candidate()))
        wait(for:[reloaded],timeout:5)
        let stopped=expectation(description:"stop reply")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try reply("stop")["ok"] as? Bool,true) }
            catch { XCTFail(String(describing:error)) }
            stopped.fulfill()
        }
        let stopUntil=Date().addingTimeInterval(3)
        while !drain.isCancelled && Date() < stopUntil { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(drain.isCancelled)
        control.finish(summary("STOPPED"))
        wait(for:[stopped],timeout:5)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("control.sock").path))
        XCTAssertThrowsError(try reply("status"))
    }
    func testControlDoesNotReplaceRegularFile() throws {
        let directory=URL(fileURLWithPath:"/tmp/repl-ctl-"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("control.sock"),contents=Data("keep me".utf8)
        try contents.write(to:path)
        let control=RunControl(limits:try .init(transactions:nil,gtids:nil),drain:.init()) { try .init(transactions:nil,gtids:nil) }
        XCTAssertThrowsError(try control.start(directory:directory))
        XCTAssertEqual(try Data(contentsOf:path),contents)
    }
}
