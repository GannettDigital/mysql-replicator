import XCTest
@testable import ReplicatorApply

final class BinlogExcerptTests:XCTestCase {
    func testLargeFileRetainsFocusAndReportsOriginalOffsets() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("binlog.000001")
        let data=Data((0..<200000).map { UInt8($0 % 251) });try data.write(to:source)
        let result=try BinlogExcerpt.collect(source,to:root,prefix:"excerpt",focus:100000..<101000,maximumBytes:8192)
        let index=try JSONDecoder().decode(BinlogExcerpt.Index.self,from:Data(contentsOf:result.files.last!))
        XCTAssertTrue(index.focusComplete);XCTAssertFalse(result.complete);XCTAssertFalse(index.standaloneReplayFile)
        XCTAssertEqual(index.sourceBytes,200000)
        XCTAssertLessThanOrEqual(index.ranges.reduce(0) {$0+$1.end-$1.start},8192)
        for range in index.ranges {
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(range.file!)),data[Int(range.start)..<Int(range.end)])
        }
        let large=try BinlogExcerpt.collect(source,to:root,prefix:"large",focus:100000..<150000,maximumBytes:4096)
        let partial=try JSONDecoder().decode(BinlogExcerpt.Index.self,from:Data(contentsOf:large.files.last!))
        XCTAssertFalse(partial.focusComplete)
    }
}
