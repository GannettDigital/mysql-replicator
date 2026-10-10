import XCTest
import Foundation
import NIOCore
import NIOPosix
import ReplicatorCapture
import ReplicatorConfiguration
@testable import ReplicatorApply

extension SupportBundleTests {
    private func helper() -> ApplyTests {
        #if os(Linux)
        return ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        return ApplyTests()
        #endif
    }
    private func failure(_ state: URL, lifecycle:String = "BLOCKED") -> ApplyRunError {
        .init(reason:"original failure",progress:.init(lifecycle:lifecycle,transactionsApplied:0,rowsApplied:0,ddlApplied:0,
            appliedPosition:nil,appliedGTIDSet:"",pendingGTID:nil,stateDirectory:state.path,stageTimings:nil,pipeline:nil,
            sourceReconnectEnabled:false,sourceReconnectAttempts:0,sourceReconnectReason:nil,
            targetReconnectEnabled:false,targetReconnectAttempts:0,targetReconnectReason:nil,targetFailure:nil,drainRequested:false))
    }

    func testAutomaticBundlesAreUniqueAndPreserveEvidenceInBothFormats() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state")
        do { let store=try StateStore(configuration:helper().config(state.path));try store.block("original failure") }
        let before=try ArchiveIO.hash(state.appendingPathComponent("state.sqlite"))
        for format in ["directory","tar"] {
            let directory=root.appendingPathComponent(format)
            let config=try ConfigurationFile.decode(SupportBundleConfiguration.self,from:Data("""
            stateDirectory: \(state.path)
            supportBundle:
              onBlocked: true
              directory: \(directory.path)
              format: \(format)
              maximumBytes: 1048576
            """.utf8))
            var outputs=Set<String>()
            for _ in 0..<2 {
                let result=try XCTUnwrap(SupportBundle.onBlocked(failure(state),configuration:config,redactedConfiguration:Data("{}".utf8),version:"test"))
                XCTAssertEqual(result.status,"collected",result.reason ?? "")
                let bundle=try XCTUnwrap(result.bundle)
                XCTAssertTrue(outputs.insert(bundle.output).inserted)
                var contents=URL(fileURLWithPath:bundle.output)
                if format == "tar" {
                    contents=root.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
                    let extract=Process();extract.executableURL=URL(fileURLWithPath:"/usr/bin/env")
                    extract.arguments=["tar","-xf",bundle.output,"-C",contents.path]
                    try extract.run();extract.waitUntilExit();XCTAssertEqual(extract.terminationStatus,0)
                } else {
                    let mode=try FileManager.default.attributesOfItem(atPath:contents.path)[.posixPermissions] as? NSNumber
                    XCTAssertEqual(mode?.intValue,0o700)
                }
                let json=try JSONSerialization.jsonObject(with:Data(contentsOf:contents.appendingPathComponent("failure.json"))) as! [String:Any]
                XCTAssertEqual(json["reason"] as? String,"original failure")
                XCTAssertEqual((json["progress"] as? [String:Any])?["lifecycle"] as? String,"BLOCKED")
                XCTAssertEqual(try helper().sqlite(contents.appendingPathComponent("state.sqlite"),"SELECT lifecycle,diagnostic FROM state"),[["BLOCKED","original failure"]])
                let index=try JSONSerialization.jsonObject(with:Data(contentsOf:contents.appendingPathComponent("bundle.json"))) as! [String:Any]
                for entry in index["files"] as! [[String:Any]] {
                    let file=contents.appendingPathComponent(entry["name"] as! String)
                    XCTAssertEqual(try ArchiveIO.hash(file),entry["sha256"] as? String)
                    let mode=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
                    XCTAssertEqual(mode?.intValue,0o600)
                }
            }
        }
        XCTAssertEqual(try ArchiveIO.hash(state.appendingPathComponent("state.sqlite")),before)
    }

    func testAutomaticBundleRequiresOptInBlockedStateAndReleasedWriter() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"),directory=root.appendingPathComponent("bundles")
        func config(_ enabled:Bool) throws -> SupportBundleConfiguration {
            try ConfigurationFile.decode(SupportBundleConfiguration.self,from:Data("""
            stateDirectory: \(state.path)
            supportBundle:
              onBlocked: \(enabled)
              directory: \(directory.path)
              format: directory
            """.utf8))
        }
        XCTAssertNil(SupportBundle.onBlocked(failure(state),configuration:try config(false),redactedConfiguration:Data(),version:"test"))
        XCTAssertNil(SupportBundle.onBlocked(failure(state,lifecycle:"STOPPED"),configuration:try config(true),redactedConfiguration:Data(),version:"test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            let store=try StateStore(configuration:helper().config(state.path));try store.block("original failure")
            let result=try XCTUnwrap(SupportBundle.onBlocked(failure(state),configuration:try config(true),redactedConfiguration:Data(),version:"test"))
            XCTAssertEqual(result.status,"failed")
            XCTAssertTrue(result.reason?.contains("active writer") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[])
        for path in [state.path,state.appendingPathComponent("nested").path] {
            let options=try ConfigurationFile.decode(SupportBundleConfiguration.Options.self,from:Data("onBlocked: true\ndirectory: \(path)".utf8))
            XCTAssertThrowsError(try options.validate(stateDirectory:state.path))
        }
        let missing=try ConfigurationFile.decode(SupportBundleConfiguration.Options.self,from:Data("onBlocked: true".utf8))
        XCTAssertThrowsError(try missing.validate(stateDirectory:state.path))
        XCTAssertThrowsError(try ConfigurationFile.decode(SupportBundleConfiguration.Options.self,from:Data("format: zip".utf8)))
    }

    /// Exercise the CLI hook after ApplyRun unwinds, without a MySQL fixture.
    /// A refused target connection enters BLOCKED during initialization.
    func testCLICollectsOnBlockedAndPreservesApplyErrorIfCollectionFails() throws {
        let root=URL(fileURLWithPath:"/tmp").appendingPathComponent("bundle-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary=(ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"] ?? project.appendingPathComponent(".build/debug").path)+"/mysql-replicator"
        let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
        defer { try? group.syncShutdownGracefully() }
        let listener=try ServerBootstrap(group:group).bind(host:"127.0.0.1",port:0).wait()
        let port=try XCTUnwrap(listener.localAddress?.port)
        try listener.close().wait()
        for blockedDirectory in [false,true] {
            let label=blockedDirectory ? "failed" : "collected",state=root.appendingPathComponent(label)
            let bundles=root.appendingPathComponent("bundles-"+label)
            if blockedDirectory { try Data("not a directory".utf8).write(to:bundles) }
            let config=root.appendingPathComponent(label+".yaml")
            try """
            version: 2
            stateDirectory: \(state.path)
            source:
              version: 2
              host: unused.invalid
              port: 3306
              username: unused
              password: source-secret
              requireTLS: false
              serverID: 9100
              sourceUUID: 00000000-0000-0000-0000-000000000001
              mode: gtid
              start:
                executedGTIDs: ''
            target:
              host: 127.0.0.1
              port: \(port)
              username: unused
              password: target-secret
              requireTLS: false
              nativeAutoStartDisabled: true
            targetReconnect:
              enabled: false
            supportBundle:
              onBlocked: true
              directory: \(bundles.path)
              format: directory
            """.write(to:config,atomically:true,encoding:.utf8)
            let errorFile=root.appendingPathComponent(label+".stderr")
            XCTAssertTrue(FileManager.default.createFile(atPath:errorFile.path,contents:nil))
            let handle=try FileHandle(forWritingTo:errorFile)
            let process=Process();process.executableURL=URL(fileURLWithPath:binary)
            process.arguments=["run","--config",config.path,"--initialize"]
            process.standardOutput=FileHandle.nullDevice;process.standardError=handle
            try process.run();process.waitUntilExit();try handle.close()
            XCTAssertEqual(process.terminationStatus,1)
            let diagnostic=try JSONSerialization.jsonObject(with:Data(contentsOf:errorFile)) as! [String:Any]
            XCTAssertEqual(diagnostic["error"] as? String,"apply_failed")
            XCTAssertEqual(diagnostic["reason"] as? String,"target connection unavailable")
            XCTAssertEqual((diagnostic["progress"] as? [String:Any])?["lifecycle"] as? String,"BLOCKED")
            let automatic=try XCTUnwrap(diagnostic["supportBundle"] as? [String:Any])
            XCTAssertEqual(automatic["status"] as? String,label)
            if !blockedDirectory {
                let bundle=try XCTUnwrap(automatic["bundle"] as? [String:Any])
                let output=URL(fileURLWithPath:try XCTUnwrap(bundle["output"] as? String))
                let redacted=try String(contentsOf:output.appendingPathComponent("configuration.json"),encoding:.utf8)
                XCTAssertFalse(redacted.contains("source-secret"));XCTAssertFalse(redacted.contains("target-secret"))
                XCTAssertEqual(try helper().sqlite(output.appendingPathComponent("state.sqlite"),"SELECT lifecycle FROM state"),[["BLOCKED"]])
            }
        }
    }
}
