import XCTest
import Foundation
@testable import ReplicatorCapture
import ReplicatorCodec

final class ArchiveTests: XCTestCase {
    var root:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func fixture(_ body:(URL,CaptureConfiguration,ArchiveConfiguration) throws -> Void) throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.copyItem(at:root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"),to:dir.appendingPathComponent("binlog.000003"))
        #if os(Linux)
        let helper=CaptureTests(name:"fixtures",testClosure:{_ in})
        #else
        let helper=CaptureTests()
        #endif
        let source=try helper.config("gtid")
        let archive=try JSONDecoder().decode(ArchiveConfiguration.self,from:JSONSerialization.data(withJSONObject:["directory":dir.path]))
        try body(dir,source,archive)
    }
    func testExternalRawDirectoryReplaysOnlyMissingGTIDsWithoutSourceAccess() throws {
        try fixture { _,source,config in
            let archive=try ArchiveReplay(configuration:config,source:source,contract:.mysql84)
            XCTAssertTrue(archive.manifest.provenance?.contains("external") == true)
            try archive.validate(baseline:source.start.executedGTIDs)
            var groups:[CompleteTransaction]=[]
            try archive.run(configuration:source,cancellation:.init(),emitEvent:{_ in},emitTransaction:{groups.append($0)},resolveSchema:nil,timings:.init(),ignoreTable:nil)
            XCTAssertEqual(groups.compactMap{$0.gtid?.sequence},["11","12","13","14"])
            XCTAssertEqual(groups[0].events.flatMap(\.rows).first?.operation,"insert")
            let resumed=source.resuming(file:nil,position:nil,executedGTIDs:source.sourceUUID+":1-11:13")
            groups=[]
            try archive.run(configuration:resumed,cancellation:.init(),emitEvent:{_ in},emitTransaction:{groups.append($0)},resolveSchema:nil,timings:.init(),ignoreTable:nil)
            XCTAssertEqual(groups.compactMap{$0.gtid?.sequence},["12","14"])
        }
    }
    func testArchiveCanHandRawBytesDirectlyToRelay() throws {
        try fixture { _,source,config in
            let archive=try ArchiveReplay(configuration:config,source:source,contract:.mysql84)
            var expected:[Data]=[],actual:[Data]=[]
            try archive.run(configuration:source,cancellation:.init(),emitEvent:{ record in
                expected.append(try XCTUnwrap((record.event?.rawBase64 ?? record.rawBase64).flatMap { Data(base64Encoded:$0) }))
            },emitTransaction:{ _ in },resolveSchema:nil,timings:.init(),ignoreTable:nil)
            try archive.run(configuration:source,cancellation:.init(),retainRawBytes:true,emitEvent:{ record in
                actual.append(try XCTUnwrap(record.rawBytes)); XCTAssertNil(record.event?.rawBase64); XCTAssertNil(record.rawBase64)
            },emitTransaction:{ _ in },resolveSchema:nil,timings:.init(),ignoreTable:nil)
            XCTAssertEqual(actual,expected); XCTAssertFalse(actual.isEmpty)
        }
    }
    func testArchiveRejectsCorruptionTruncationAndMissingBaselineHistory() throws {
        try fixture { dir,source,config in
            let original=try Data(contentsOf:dir.appendingPathComponent("binlog.000003"))
            let valid=try ArchiveReplay(configuration:config,source:source,contract:.mysql84)
            XCTAssertThrowsError(try valid.validate(baseline:""))
            for corrupt in [Data(original.dropLast()), {var d=original;d[d.count-12] ^= 1;return d}()] {
                try corrupt.write(to:dir.appendingPathComponent("binlog.000003"))
                XCTAssertThrowsError(try ArchiveReplay(configuration:config,source:source,contract:.mysql84).validate(baseline:source.start.executedGTIDs))
            }
            // A complete frame boundary inside a transaction is still incomplete.
            var last=4,offset=4
            while offset < original.count { if original[offset+4] == 16 { last=offset };offset += Int(ArchiveIO.read(original.subdata(in:offset..<offset+19),at:9,as:UInt32.self)) }
            try original.prefix(last).write(to:dir.appendingPathComponent("binlog.000003"))
            XCTAssertThrowsError(try ArchiveReplay(configuration:config,source:source,contract:.mysql84).validate(baseline:source.start.executedGTIDs))
        }
    }
    func testManifestTamperingAndUnsafeNamesFailBeforeReplay() throws {
        try fixture { dir,source,config in
            let archive=try ArchiveReplay(configuration:config,source:source,contract:.mysql84)
            try ArchiveIO.write(archive.manifest,to:dir.appendingPathComponent("manifest.json"))
            XCTAssertNoThrow(try ArchiveReplay(configuration:config,source:source,contract:.mysql84))
            let path=dir.appendingPathComponent("binlog.000003"),handle=try FileHandle(forWritingTo:path)
            try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
            XCTAssertThrowsError(try ArchiveReplay(configuration:config,source:source,contract:.mysql84))
        }
        for name in ["../binlog","/tmp/binlog","a/b","..","a\\b"] { XCTAssertThrowsError(try ArchiveIO.filename(name)) }
    }
    func testExternalFileSelectionAndIncompleteFetchMarker() throws {
        try fixture { dir,source,config in
            try Data("unrelated notes".utf8).write(to:dir.appendingPathComponent("notes.txt"))
            XCTAssertThrowsError(try ArchiveReplay(configuration:config,source:source,contract:.mysql84).validate(baseline:source.start.executedGTIDs))
            let selected=try JSONDecoder().decode(ArchiveConfiguration.self,from:JSONSerialization.data(withJSONObject:["directory":dir.path,"files":["binlog.000003"]]))
            let archive=try ArchiveReplay(configuration:selected,source:source,contract:.mysql84)
            try archive.validate(baseline:source.start.executedGTIDs)
            try ArchiveIO.write(archive.manifest,to:dir.appendingPathComponent("manifest.json"))
            try Data().write(to:dir.appendingPathComponent("incomplete.json"))
            XCTAssertThrowsError(try ArchiveReplay(configuration:selected,source:source,contract:.mysql84)) {
                XCTAssertTrue(String(describing:$0).contains("incomplete"))
            }
        }
    }
    func testGTIDStopIsInclusivePreservesHolesAndCombinesWithCount() throws {
        try fixture { _,source,config in
            let archive=try ArchiveReplay(configuration:config,source:source,contract:.mysql84)
            var limited=source
            limited.stopAfterGTIDs=source.sourceUUID+":1-12"
            limited.stopAfterTransactions=100
            func run(_ source:CaptureConfiguration) throws -> [String] {
                var ids:[String]=[]
                try archive.run(configuration:source,cancellation:.init(),emitEvent:{_ in},emitTransaction:{ids.append($0.gtid!.sequence)},resolveSchema:nil,timings:.init(),ignoreTable:nil)
                return ids
            }
            XCTAssertEqual(try run(limited),["11","12"])
            limited.stopAfterTransactions=1
            XCTAssertEqual(try run(limited),["11"])
            limited.stopAfterTransactions=nil
            limited.stopAfterGTIDs=source.sourceUUID+":12:14"
            XCTAssertEqual(try run(limited),["11","12","13","14"])
            let resumed=limited.resuming(file:nil,position:nil,executedGTIDs:source.sourceUUID+":1-11:13-14")
            XCTAssertEqual(try run(resumed),["12"])
            XCTAssertEqual(try run(limited.resuming(file:nil,position:nil,executedGTIDs:source.sourceUUID+":1-14")),[])
            limited.stopAfterGTIDs=source.sourceUUID+":999"
            var emitted=false
            XCTAssertThrowsError(try archive.run(configuration:limited,cancellation:.init(),emitEvent:{_ in emitted=true},emitTransaction:{_ in emitted=true},resolveSchema:nil,timings:.init(),ignoreTable:nil))
            XCTAssertFalse(emitted)
        }
    }
}
