import XCTest
import Foundation
@testable import ReplicatorCapture
import ReplicatorCodec

extension CaptureTests {
    private var cachedColumns: [ColumnInterpretation] { [.signed,.utf8,.unsigned] }

    // Replay real, checksummed row events at a new physical position/GTID.
    private func feedCachedGroup(_ p: StreamProcessor, sequence: UInt64) throws {
        for (_, original) in try recorded() where original[4] != 4 {
            // Only the first complete INSERT transaction is needed here.
            let oldNext=readNext(original)
            guard oldNext > 1589 && oldNext <= 1885 else { continue }
            var event=original
            if event[4] == 33 { event.replaceSubrange(36..<44,with:le(sequence)) }
            event.replaceSubrange(13..<17,with:le(UInt32(p.cursor!.position)+UInt32(event.count)))
            try p.consume(seal(event))
        }
    }
    private func readNext(_ event: Data) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(event[13+$1]) << (8*$1) }
    }

    func testHistoricalSchemaCacheReusesChangingTableIDsButRechecksWireShape() throws {
        for changedShape in [false,true] {
            var calls=0, maps=0
            let timings=StageTimings()
            let p=try StreamProcessor(config:config(version:2),includeRaw:true,emitEvent:{ _ in },emitTransaction:{ _ in },resolveSchema:{ _,_ in
                calls += 1; return self.cachedColumns
            },timings:timings)
            try begin(p)
            for (offset,original) in try recorded() where offset >= 1589 && original[4] != 4 {
                var event=original
                if event[4] == 19 {
                    maps += 1
                    // The golden map has three columns; byte 46 is its null bitmap.
                    if changedShape && maps == 2 { event[46] ^= 1 }
                }
                if [19,30,31,32].contains(event[4]) {
                    event.replaceSubrange(19..<25,with:le(UInt64(100+maps)).prefix(6))
                }
                try p.consume(seal(event))
            }
            try p.finish()
            XCTAssertEqual(p.transactionCount,4)
            XCTAssertEqual(calls,changedShape ? 3 : 1)
            XCTAssertEqual(timings.snapshot["capture.schema_cache.hit"]?.count,changedShape ? 1 : 3)
            XCTAssertEqual(timings.snapshot["capture.schema_cache.miss"]?.count,UInt64(calls))
        }
    }

    func testHistoricalSchemaCacheInvalidatesIdenticalMapsAfterDDL() throws {
        for sql in ["ALTER TABLE items MODIFY id INT UNSIGNED", "RENAME TABLE items TO old_items",
                    "DROP TABLE items", "CREATE TABLE items(id INT)"] {
            var calls=0, ddlPublished=false
            let p=try StreamProcessor(config:config(version:2),includeRaw:false,emitEvent:{ _ in },emitTransaction:{ group in
                if group.events.contains(where:{ if case .query(let q) = $0.control { return q.sql == Data(sql.utf8) }; return false }) { ddlPublished=true }
            },resolveSchema:{ _,_ in
                calls += 1
                if calls == 2 { XCTAssertTrue(ddlPublished,"lookup must follow the published DDL") }
                return self.cachedColumns
            },allowDDL:true)
            try begin(p); try feedCachedGroup(p,sequence:11)
            var gtid=try recorded().first { $0.0 == 1589 }!.1
            gtid.replaceSubrange(36..<44,with:le(UInt64(12)))
            gtid.replaceSubrange(13..<17,with:le(UInt32(p.cursor!.position)+UInt32(gtid.count)))
            try p.consume(seal(gtid))
            var body=le(UInt32(1))+le(UInt32(0))
            body += Data([3])+le(UInt16(0))+le(UInt16(0))+Data("poc\0".utf8)+Data(sql.utf8)
            try p.consume(frame(2,body:body,next:UInt32(p.cursor!.position)+UInt32(body.count+23)))
            try feedCachedGroup(p,sequence:13); try p.finish()
            XCTAssertEqual(calls,2,sql)
            XCTAssertEqual(p.transactionCount,3)
        }
    }

    func testHistoricalSchemaCacheIsFreshAfterRotationAndNewProcessor() throws {
        var calls=0
        for _ in 0..<2 {
            let p=try StreamProcessor(config:config(version:2),includeRaw:false,emitEvent:{ _ in },emitTransaction:{ _ in },resolveSchema:{ _,_ in
                calls += 1; return self.cachedColumns
            })
            try begin(p); try feedCachedGroup(p,sequence:11)
            let body=le(UInt64(4))+Data("binlog.000004".utf8)
            try p.consume(frame(4,body:body,next:UInt32(p.cursor!.position)+UInt32(body.count+23)))
            try p.consume(announce("binlog.000004",4)); try p.consume(fde(4))
            try feedCachedGroup(p,sequence:12); try p.finish()
        }
        XCTAssertEqual(calls,4)
    }

    func testHistoricalSchemaCacheInvalidatesExcludedRanges() throws {
        for archive in [false,true] {
            var calls=0
            let p=try StreamProcessor(config:config("gtid",version:2),includeRaw:false,emitEvent:{ _ in },emitTransaction:{ _ in },resolveSchema:{ _,_ in
                calls += 1; return self.cachedColumns
            })
            try begin(p,position:4); try p.consume(recorded()[1].1)
            try p.consume(frame(27,body:Data("binlog.000003".utf8),next:1589))
            try feedCachedGroup(p,sequence:11)
            let next=UInt32(p.cursor!.position)+100
            if archive { try p.skipArchivedGroup(to:.init(file:"binlog.000003",position:UInt64(next))) }
            else { try p.consume(frame(27,body:Data("binlog.000003".utf8),next:next)) }
            try feedCachedGroup(p,sequence:12); try p.finish()
            XCTAssertEqual(calls,2)
        }
    }

    func testHistoricalSchemaCacheDoesNotBypassChecksumOrResolveFilteredTables() throws {
        var calls=0
        let p=try StreamProcessor(config:config(version:2),includeRaw:false,emitEvent:{ _ in },emitTransaction:{ _ in },resolveSchema:{ _,_ in
            calls += 1; return self.cachedColumns
        })
        try begin(p)
        for (offset,original) in try recorded() where offset >= 1589 {
            var event=original
            if offset == 2044 {
                event[event.count-1] ^= 1
                XCTAssertThrowsError(try p.consume(event))
                break
            }
            try p.consume(event)
        }
        XCTAssertEqual(calls,1)
        let filtered=try StreamProcessor(config:config(version:2),includeRaw:false,emitEvent:{ _ in },emitTransaction:{ _ in },resolveSchema:{ _,_ in
            XCTFail("filtered table requested schema"); return []
        },ignoreTable:{ _,_ in true })
        try begin(filtered)
        for (offset,event) in try recorded() where offset >= 1589 { try filtered.consume(event) }
        try filtered.finish(); XCTAssertEqual(filtered.transactionCount,4)
    }
}
