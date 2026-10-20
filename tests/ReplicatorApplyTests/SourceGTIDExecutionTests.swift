import CSQLite
import Foundation
import MySQLNIO
import NIOCore
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class SourceGTIDExecutionTests: XCTestCase {
    func testTargetVersionGateDoesNotFlattenTags() throws {
        let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try SourceGTIDExecution.validate(SourceGTID(parsing: sid + ":9"), targetVersion: 50742)
        let tagged = try SourceGTID(parsing: sid + ":blue:9")
        XCTAssertThrowsError(try SourceGTIDExecution.validate(tagged, targetVersion: 50742)) {
            XCTAssertTrue(String(describing: $0).contains(tagged.canonical))
        }
        try SourceGTIDExecution.validate(tagged, targetVersion: 80408)
    }
    func testScratchBindsKeepProtocolTypesAndQuotedQuestionMarks() throws {
        var program = MyISAMGTIDProgram()
        let value = try FloatingPointSQL.bind(.float64(0x8000_0000_0000_0000))
        let sql = try program.expand(
            "UPDATE `a?``b` SET `x`=?,`y`='literal?''?' WHERE `z`=?", [value, .init(string: "secret '? text")])
        XCTAssertTrue(sql.contains("`a?``b`"))
        XCTAssertTrue(sql.contains("'literal?''?'"))
        XCTAssertFalse(sql.contains("secret"))
        XCTAssertEqual(program.values.map(\.0), ["d", "t"])
        XCTAssertEqual(program.values[0].1.buffer, value.buffer)
        XCTAssertThrowsError(try program.expand("SELECT ?", []))
        XCTAssertThrowsError(try program.expand("SELECT 1", [.null]))
    }
    func testGTIDPreservationIsPinnedAndLegacyStateRequiresExplicitFalse() throws {
        #if os(Linux)
            let helper = ApplyTests(name: "fixtures", testClosure: { _ in })
        #else
            let helper = ApplyTests()
        #endif
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let path = parent.appendingPathComponent("state").path
        let preserve = try helper.config(path, preserveSourceGTIDs: true)
        let local = try helper.config(path)
        do {
            let store = try StateStore(configuration: preserve)
            try store.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
            try store.running()
            try store.stopped()
        }
        XCTAssertNoThrow(try StateStore(configuration: preserve, initialize: false))
        XCTAssertThrowsError(try StateStore(configuration: local, initialize: false))
        let db = URL(fileURLWithPath: path).appendingPathComponent("state.sqlite")
        try writeGTIDTestState(db, "PRAGMA user_version=11")
        XCTAssertThrowsError(try StateStore(configuration: preserve, initialize: false)) {
            XCTAssertTrue(String(describing: $0).contains("legacy state did not preserve source GTIDs"))
        }
        XCTAssertNoThrow(try StateStore(configuration: local, initialize: false))
        XCTAssertEqual(try helper.sqlite(db, "PRAGMA user_version"), [["13"]])
    }
}

func writeGTIDTestState(_ file: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        throw ApplyError("test state open failed")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ApplyError("test state mutation failed") }
}
