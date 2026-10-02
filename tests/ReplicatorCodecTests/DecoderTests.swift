import XCTest
import Foundation
import ReplicatorCodec
import ReplicatorLabCore
import CReplicatorCodec

final class DecoderTests: XCTestCase, BinlogFixtures {
    func testProfilingPreservesDecodedValuesAndRecordsFailedCRC() throws {
        let input = frames(try Data(contentsOf:directory.appendingPathComponent("Synthetic/typed.binlog")))
        let history = try schema("typed").indexed()
        let timings = StageTimings()
        let profiled = try BinlogDecoder(timings:timings), plain = try BinlogDecoder()
        for (offset,frame) in input {
            XCTAssertEqual(try profiled.decode(frame,at:offset,schema:history[offset],includeRaw:true),
                           try plain.decode(frame,at:offset,schema:history[offset],includeRaw:true))
        }
        for stage in ["decode.rust","decode.rust.crc32","decode.rust.sha256","decode.swift.fingerprint_hex","decode.swift.result_free"] {
            XCTAssertEqual(timings.snapshot[stage]?.count,UInt64(input.count),stage)
            XCTAssertEqual(timings.snapshot[stage]?.failures,0,stage)
        }
        XCTAssertEqual(timings.snapshot["decode.rust.rows"]?.count,UInt64(input.filter { [23,24,25,30,31,32].contains($0.1[4]) }.count))
        try profiled.reset()
        var corrupt=input[0].1; corrupt[corrupt.count-1] ^= 1
        failure(3) { _ = try profiled.decode(corrupt,at:4) }
        failure(6) { _ = try profiled.decode(input[0].1,at:4) }
        XCTAssertEqual(timings.snapshot["decode.rust.crc32"]?.failures,1)
        XCTAssertEqual(timings.snapshot["decode.rust"]?.failures,1)
        XCTAssertEqual(timings.snapshot["decode.swift.result_free"]?.count,UInt64(input.count+1))
        try profiled.reset()
        XCTAssertNoThrow(try profiled.decode(input[0].1,at:4))
    }

    func testYearAndDecimalConsumeNumericSignednessWithoutConsumingCharsetMetadata() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4)
        // YEAR, DECIMAL(10,2), TINYINT, VARCHAR(10); signedness 110, charset utf8mb4_bin.
        let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,4,13,246,1,15,4,10,2,40,0,15,1,1,192,2,1,46])
        let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let map=try decoder.decode(event(19,body,at:at),at:at)
        XCTAssertEqual(map.wireColumns?.map(\.interpretation),[.temporal,.decimal,.signed,.utf8])
        XCTAssertEqual(map.wireColumns?.map(\.isUnsigned),[true,true,false,nil])
        XCTAssertEqual(map.wireColumns?.last?.collation,46)
        XCTAssertEqual(map.wireColumns?[1].metadata,Data([10,2]))
    }
    func testSignedMediumintSignExtensionFromIndependentWireBytes() throws {
        let fde=frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at=UInt64(fde.count+4)
        let body=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,1,9,0,0])
        let map=event(19,body,at:at)
        let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let identity=try decoder.decode(map,at:at)
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        _ = try decoder.decode(map,at:at,schema:TableSchema(offset:at,eventSHA256:identity.sha256,database:"poc",table:"x",tableID:"123",columns:[.signed]))
        // Header then three non-NULL values: minimum, -1, maximum.
        let rows=Data([123,0,0,0,0,0,1,0,2,0,1,1,0,0,0,128,0,255,255,255,0,255,255,127])
        let result=try decoder.decode(event(30,rows,at:at+UInt64(map.count)),at:at+UInt64(map.count))
        XCTAssertEqual(result.rows.compactMap{$0.after?.first},[.signed(-8388608),.signed(-1),.signed(8388607)])
    }
    func testFilteredUnsupportedColumnMapIsOpaqueButStillChecksRowsAndClearsMaps() throws {
        let fde = frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let at = UInt64(fde.count+4)
        // One JSON column, nullable; still outside the qualified decoder subset.
        let body = Data([123,0,0,0,0,0,0,0,3])+Data("tmp".utf8)+Data([0,1,120,0,1,245,1,4,1])
        let map = event(19,body,at:at)
        let strict = try BinlogDecoder(); _ = try strict.decode(fde,at:4)
        failure(4) { _ = try strict.decode(map,at:at) }
        let decoder = try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let identity = try decoder.decode(map,at:at,filterTable:true)
        XCTAssertEqual(identity.database,"tmp"); XCTAssertTrue(identity.replicationFiltered)
        let rowOffset=at+UInt64(map.count)
        // v2 write rows: table 123, STMT_END, extra length 2, one present
        // column, NULL row. No value interpretation is needed.
        let row = event(30,Data([123,0,0,0,0,0,1,0,2,0,1,1,1]),at:rowOffset)
        let ignored = try decoder.decode(row,at:rowOffset)
        XCTAssertTrue(ignored.replicationFiltered); XCTAssertTrue(ignored.rows.isEmpty)
        XCTAssertEqual(ignored.rowFlags,1)
        failure(7) { _ = try decoder.decode(event(30,Data(row[19..<row.count-4]),at:rowOffset+UInt64(row.count)),at:rowOffset+UInt64(row.count)) }
        try decoder.reset(); _ = try decoder.decode(fde,at:4)
        failure(1) { _ = try decoder.decode(event(3,Data(),at:at),at:at,filterTable:true) }
    }
    func testAutomaticWireMetadataSurvivesResetAndRejectsConflictingTLVs() throws {
        let fde = frames(try Data(contentsOf:recorded.appendingPathComponent("source-positive.binlog")))[0].1
        let offset=UInt64(4+fde.count)
        // Independently authored INT UNSIGNED, VARCHAR(10) utf8mb4 table map.
        let base=Data([123,0,0,0,0,0,0,0,3])+Data("poc".utf8)+Data([0,1,120,0,2,3,15,2,40,0,2])
        let minimal=Data([1,1,128,2,1,45])
        let full=minimal+Data([4,5,2,105,100,1,118,8,1,0])
        for metadata in [minimal,full] {
            let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
            let event=try decoder.decode(self.event(19,base+metadata,at:offset),at:offset)
            try decoder.reset()
            let columns=try XCTUnwrap(event.wireColumns)
            XCTAssertEqual(columns.map(\.interpretation),[.unsigned,.utf8])
            XCTAssertEqual(columns.map(\.nullable),[false,true])
            XCTAssertEqual(columns.map(\.maximumBytes),[0,40])
            XCTAssertEqual(columns[1].collation,45)
            XCTAssertEqual(columns.map(\.name),metadata==minimal ? [nil,nil] : ["id","v"])
            XCTAssertEqual(columns[0].primaryKey,metadata==full)
        }
        for metadata in [minimal+Data([1,1,0]),minimal+Data([3,1,45]),minimal+Data([4,2,1,105])] {
            let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
            failure(2) {_ = try decoder.decode(self.event(19,base+metadata,at:offset),at:offset)}
        }
        let decoder=try BinlogDecoder(); _ = try decoder.decode(fde,at:4)
        let missing=try decoder.decode(event(19,base,at:offset),at:offset)
        XCTAssertEqual(missing.wireColumns?.map(\.interpretation),[nil,nil])
    }
    func testRecordedCorpusMatchesIndependentMySQLReference() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: recorded.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        for entry in manifest {
            let name = (entry["raw"] as! String).replacingOccurrences(of: ".binlog", with: "")
            let start = (entry["start"] as! NSNumber).uint64Value, end = (entry["end"] as! NSNumber).uint64Value
            let expected = try BinlogReference.parse(String(contentsOf: recorded.appendingPathComponent(entry["text"] as! String), encoding: .utf8), from: start, before: end)
            var operations: [RowOperation] = []
            func values(_ row: [DecodedValue]?) throws -> [String]? {
                try row?.map { value in
                    switch value { case .signed(let n): return String(n); case .unsigned(let n): return String(n); case .text(let s): return s
                    default: throw LabError("unexpected recorded corpus value") }
                }
            }
            try Inspection.inspect(file: recorded.appendingPathComponent(entry["raw"] as! String), history: schema(name)) { record in
                guard let pos = UInt64(record.offset), pos >= start, pos < end else { return }
                for row in record.rows { operations.append(RowOperation(row.operation, before: try values(row.before), after: try values(row.after))) }
            }
            XCTAssertEqual(operations, expected, name)
            XCTAssertEqual(operations, name == "native-rejected" ? Array(Fixture.operations.prefix(1)) : Fixture.operations)
        }
    }
    func testExactValuesNullBinaryAndMinimalImages() throws {
        var rows: [DecodedRow] = []
        try Inspection.inspect(file: directory.appendingPathComponent("Synthetic/typed.binlog"), history: schema("typed")) { rows += $0.rows }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].after, [.signed(-128), .unsigned(65535), .signed(-2147483648), .unsigned(.max), .text("hé\0😀"), .binary(Data([0,255,128])), .null])
        XCTAssertEqual(rows[1].after, [.signed(127), .unsigned(0), .signed(2147483647), .unsigned(0), .text(""), .binary(Data()), .binary(Data([0xde,0xad,0xbe,0xef]))])
        XCTAssertEqual(rows[2].before, [.signed(-128), .absent, .absent, .absent, .absent, .absent, .absent])
        XCTAssertEqual(rows[2].after, [.absent, .absent, .absent, .absent, .absent, .absent, .null])
        let encoded = try JSONEncoder().encode(rows)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Synthetic/typed-rows.json"))) as! NSArray
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSArray, expected)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("18446744073709551615")); XCTAssertTrue(json.contains("AP+A")); XCTAssertTrue(json.contains("absent"))
    }
    func testSigned64AndUnsignedHighBitsAcrossSwiftABI() throws {
        let fde = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        for kind in [ColumnInterpretation.signed, .unsigned] {
            let decoder = try BinlogDecoder(); _ = try decoder.decode(fde, at: 4)
            let offset = UInt64(4 + fde.count)
            let table = event(19, Data([123,0,0,0,0,0,0,0,3]) + Data("poc".utf8) + Data([0,1,120,0,1,8,0,1]), at: offset)
            // Query the frame identity, then supply independently authored type
            // history and expected values on a fresh context.
            let identity = try decoder.decode(table, at: offset)
            try decoder.reset(); _ = try decoder.decode(fde, at: 4)
            let history = TableSchema(offset: offset, eventSHA256: identity.sha256, database: "poc", table: "x", tableID: "123", columns: [kind])
            _ = try decoder.decode(table, at: offset, schema: history)
            let rowOffset = offset + UInt64(table.count)
            let raw = Data([123,0,0,0,0,0,1,0,2,0,1,1,0]) + le(UInt64(0x8000000000000000)) + Data([0]) + le(UInt64.max)
            let rows = try decoder.decode(event(30, raw, at: rowOffset), at: rowOffset).rows
            XCTAssertEqual(rows.map(\.after), kind == .signed ? [[.signed(.min)], [.signed(-1)]] : [[.unsigned(0x8000000000000000)], [.unsigned(.max)]])
        }
    }
    func testTableMapCacheIsBounded() throws {
        let input = frames(try Data(contentsOf: directory.appendingPathComponent("Synthetic/typed.binlog")))
        let decoder = try BinlogDecoder(); _ = try decoder.decode(input[0].1, at: 4)
        var offset = input[1].0
        for id in 1...65 {
            var payload = Data(input[1].1.dropFirst(19).dropLast(4)); payload[0] = UInt8(id)
            let frame = event(19, payload, at: offset)
            if id == 65 { failure(5) { _ = try decoder.decode(frame, at: offset) } }
            else { _ = try decoder.decode(frame, at: offset) }
            offset += UInt64(frame.count)
        }
    }
    func testCRCFailurePoisonsAndResetRequiresReplay() throws {
        let input = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))
        let decoder = try BinlogDecoder()
        _ = try decoder.decode(input[0].1, at: 4)
        var bad = input[1].1; bad[20] ^= 1
        failure(3) { _ = try decoder.decode(bad, at: input[1].0) }
        failure(6) { _ = try decoder.decode(input[1].1, at: input[1].0) }
        try decoder.reset()
        failure(2) { _ = try decoder.decode(input[1].1, at: 4) }
        try decoder.reset()
        XCTAssertEqual(try decoder.decode(input[0].1, at: 4).eventType, 15)
    }
    func testUnknownEventsAndCompressionAreExplicitFailures() throws {
        let input = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))
        for code: UInt8 in [255, 40, 41, 42] {
            let decoder = try BinlogDecoder(); _ = try decoder.decode(input[0].1, at: 4)
            failure(4) { _ = try decoder.decode(event(code, Data(), at: input[1].0), at: input[1].0) }
        }
    }
    func testShortFramesExtraBytesAndNoncontiguousInput() throws {
        let fde = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        for bad in [Data(fde.prefix(18)), Data(fde.dropLast()), fde + Data([0])] {
            failure(2) { _ = try BinlogDecoder().decode(bad, at: 4) }
        }
        failure(2) { _ = try BinlogDecoder().decode(fde, at: 5) }
        failure(5) { _ = try BinlogDecoder(maximumEventBytes: 23).decode(fde, at: 4) }
        failure(1) { _ = try BinlogDecoder(maximumEventBytes: 0) }
    }
    func testOfflineTruncationAndOversizedHeaderCannotBecomeEOF() throws {
        let input = try Data(contentsOf: directory.appendingPathComponent("Synthetic/typed.binlog"))
        for count in [1, 3, 4, input.count-1, input.count-10, input.count-22] {
            try temporary(Data(input.prefix(count))) { url in
                failure(2) { try Inspection.inspect(file: url, history: count > 4 ? schema("typed") : nil) { _ in } }
            }
        }
        let fde = frames(input)[0].1
        var oversized = event(3, Data(), at: UInt64(fde.count+4))
        oversized.replaceSubrange(9..<13, with: le(UInt32.max))
        try temporary(Data([0xfe,0x62,0x69,0x6e]) + fde + oversized) { url in
            failure(5) { try Inspection.inspect(file: url) { _ in } }
        }
    }
    func testMissingMismatchedAndDuplicateHistoryFailClosed() throws {
        let url = directory.appendingPathComponent("Synthetic/typed.binlog")
        failure(7) { try Inspection.inspect(file: url) { _ in } }
        let history = try schema("typed"), entry = history.tableMaps[0]
        let bad = TableSchema(offset: entry.offset, eventSHA256: String(repeating: "0", count: 64), database: entry.database, table: entry.table, tableID: entry.tableID, columns: entry.columns)
        failure(7) { try Inspection.inspect(file: url, history: SchemaHistory(tableMaps: [bad])) { _ in } }
        failure(1) { _ = try SchemaHistory(tableMaps: [entry,entry]).indexed() }
    }
    func testPreviousGTIDCountsAreBoundedBeforeAllocation() throws {
        let input = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))
        let bodies = [le(UInt64(65)), le(UInt64(1)) + Data(repeating: 0, count: 16) + le(UInt64.max)]
        for body in bodies {
            let decoder = try BinlogDecoder(); _ = try decoder.decode(input[0].1, at: 4)
            failure(5) { _ = try decoder.decode(event(35, body, at: input[1].0), at: input[1].0) }
        }
    }
    func testRowLimitPublishesNoPartialBatch() throws {
        let input = frames(try Data(contentsOf: directory.appendingPathComponent("Synthetic/typed.binlog")))
        let decoder = try BinlogDecoder(); _ = try decoder.decode(input[0].1, at: 4)
        _ = try decoder.decode(input[1].1, at: input[1].0, schema: try schema("typed").tableMaps[0])
        let payload = Data(input[2].1[19..<31]) + Data(repeating: 0x7f, count: 4097)
        failure(5) { _ = try decoder.decode(event(30, payload, at: input[2].0), at: input[2].0) }
    }
    func testInvalidUTF8AndUnsupportedColumnKinds() throws {
        let input = frames(try Data(contentsOf: directory.appendingPathComponent("Synthetic/typed.binlog")))
        let history = try schema("typed")
        var row = input[2].1
        let textStart = 19 + 12 + 1 + 1 + 2 + 4 + 8 + 2
        row[textStart] = 0xff; row = reseal(row)
        let decoder = try BinlogDecoder(); _ = try decoder.decode(input[0].1, at: 4)
        _ = try decoder.decode(input[1].1, at: input[1].0, schema: history.tableMaps[0])
        failure(2) { _ = try decoder.decode(row, at: input[2].0) }
        let entry = history.tableMaps[0]
        let wrong = TableSchema(offset: entry.offset, eventSHA256: entry.eventSHA256, database: entry.database, table: entry.table, tableID: entry.tableID, columns: Array(repeating: .binary, count: 7))
        let other = try BinlogDecoder(); _ = try other.decode(input[0].1, at: 4)
        failure(7) { _ = try other.decode(input[1].1, at: input[1].0, schema: wrong) }
    }
    func testFDEInUseFlagChecksumConvention() throws {
        var fde = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        fde[17] |= 1 // MySQL changes this flag without recomputing the checksum.
        XCTAssertEqual(try BinlogDecoder().decode(fde, at: 4).eventType, 15)
        fde[fde.count-5] = 0
        failure(4) { _ = try BinlogDecoder().decode(fde, at: 4) }
    }
    func testCABIResultOutlivesInputAndContextAndChecksBounds() throws {
        let frame = frames(try Data(contentsOf: recorded.appendingPathComponent("source-positive.binlog")))[0].1
        for _ in 0..<100 {
            var context: OpaquePointer?, result: OpaquePointer?
            XCTAssertEqual(rc_decoder_create(4*1024*1024, &context), 0)
            var input = frame
            XCTAssertEqual(input.withUnsafeBytes { rc_decoder_feed(context, $0.bindMemory(to: UInt8.self).baseAddress, UInt64($0.count), 4, nil, 0, &result) }, 0)
            input.resetBytes(in: 0..<input.count)
            rc_decoder_free(context)
            var info = rc_event()
            XCTAssertEqual(rc_result_event(result, &info), 0)
            XCTAssertEqual(Data(bytes: info.raw.data!, count: Int(info.raw.length)), frame)
            var value = rc_value()
            XCTAssertEqual(rc_result_value(result, 0, 0, 0, &value), 1)
            rc_result_free(result)
        }
        XCTAssertEqual(rc_decoder_create(1024, nil), 1)
        XCTAssertEqual(rc_decoder_reset(nil), 1)
        XCTAssertEqual(rc_result_event(nil, nil), 1)
        rc_decoder_free(nil); rc_result_free(nil)
    }
    func testCABIErrorLifetimeAndNullArgumentsPoisonContext() throws {
        var context: OpaquePointer?, result: OpaquePointer?
        XCTAssertEqual(rc_decoder_create(1024, &context), 0)
        XCTAssertEqual(rc_decoder_feed(context, nil, 10, 4, nil, 0, &result), 1)
        rc_decoder_free(context)
        var info = rc_event()
        XCTAssertEqual(rc_result_event(result, &info), 0)
        XCTAssertEqual(String(decoding: Data(bytes: info.error.data!, count: Int(info.error.length)), as: UTF8.self), "null input buffer")
        rc_result_free(result)
    }
    func testInspectionCancellationAndRawOptIn() throws {
        let file = directory.appendingPathComponent("Synthetic/typed.binlog")
        var count = 0
        failure(1) { try Inspection.inspect(file: file, history: schema("typed"), cancelled: { count == 1 }) { event in count += 1; XCTAssertNil(event.rawBase64) } }
        XCTAssertEqual(count, 1)
        var raw = Data([0xfe,0x62,0x69,0x6e])
        try Inspection.inspect(file: file, history: schema("typed"), includeRaw: true) { raw.append(Data(base64Encoded: $0.rawBase64!)!) }
        XCTAssertEqual(raw, try Data(contentsOf: file))
    }
    func testCLIOutputAndExitStatus() throws {
        let runner = ProcessRunner(root: root)
        let good = try runner.run([(ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"] ?? root.appendingPathComponent(".build/debug").path) + "/mysql-replicator", "inspect", directory.appendingPathComponent("Synthetic/typed.binlog").path, "--schema", directory.appendingPathComponent("Schema/typed.json").path])
        XCTAssertTrue(good.stderr.isEmpty)
        for line in good.text.split(separator: "\n") { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        let bad = try runner.run([(ProcessInfo.processInfo.environment["REPLICATOR_TEST_BINARY_DIR"] ?? root.appendingPathComponent(".build/debug").path) + "/mysql-replicator", "inspect", directory.appendingPathComponent("Synthetic/typed.binlog").path], checked: false)
        XCTAssertNotEqual(bad.status, 0)
        let diagnostic = try JSONSerialization.jsonObject(with: bad.stderr) as! [String: Any]
        XCTAssertEqual(diagnostic["code"] as? Int, 7)
        XCTAssertEqual(bad.text.split(separator: "\n").count, 2) // FDE and map, no rows from failed event.
    }
}
