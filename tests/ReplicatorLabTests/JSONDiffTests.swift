import Foundation
import XCTest

@testable import ReplicatorLabCore

final class JSONDiffTests: XCTestCase {
    private let check = LabJSONDiff.Check(writeID: "replace", table: "poc.matrix_jsonpartial", operation: .replace)
    private func result(
        file: String = "binlog.000003", start: UInt64 = 100, end: UInt64 = 400, gtids: String = "uuid:2"
    ) -> LabSQLPhase.Result {
        .init(
            write: .init(id: "replace", sql: "UPDATE fixture"),
            start: .init(file: "binlog.000003", position: start, gtids: "uuid:1"),
            end: .init(file: file, position: end, gtids: "uuid:1-2"), gtids: gtids, warnings: "")
    }
    // Shape taken from the saved mysqlbinlog output. These offsets and expected
    // values are independent of the production binlog decoder.
    private let text = """
        # at 198
        # Start: binlog v 4
        # at 100
        # server id 8401 end_log_pos 179 CRC32 0x0 GTID
        SET @@SESSION.GTID_NEXT= 'uuid:2'/*!*/;
        # at 179
        # server id 8401 end_log_pos 200 CRC32 0x0 Table_map: `poc`.`matrix_jsonpartial`
        # at 200
        # server id 8401 end_log_pos 369 CRC32 0x0 Update_rows_partial: table id 103 flags: STMT_END_F
        ### UPDATE `poc`.`matrix_jsonpartial`
        ### WHERE
        ###   @1=1
        ###   @2='before'
        ### SET
        ###   @1=1
        ###   @2=JSON_REPLACE(@2, '$.a[1]', 123.45)
        # at 369
        # server id 8401 end_log_pos 400 CRC32 0x0 Xid = 1
        SET @@SESSION.GTID_NEXT= 'AUTOMATIC' /* added by mysqlbinlog */ /*!*/;
        """

    func testPartialEventNeedsExpectedGTIDTableOperationAndBoundedOffsets() throws {
        let proof = try check.verify(text, result: result())
        XCTAssertEqual(proof["eventType"] as? String, "Update_rows_partial")
        XCTAssertEqual(proof["eventPosition"] as? UInt64, 200)
        XCTAssertEqual(proof["eventEndPosition"] as? UInt64, 369)
        XCTAssertEqual(proof["table"] as? String, "poc.matrix_jsonpartial")
        let remove = LabJSONDiff.Check(writeID: "replace", table: check.table, operation: .remove)
        XCTAssertNoThrow(
            try remove.verify(
                text.replacingOccurrences(of: "JSON_REPLACE(@2, '$.a[1]', 123.45)", with: "JSON_REMOVE(@2, '$.a[0]')"),
                result: result()))
        XCTAssertThrowsError(try remove.verify(text, result: result()))
    }
    func testFullImagesWrongTableOrGTIDAndBeforeImagesCannotProveADiff() {
        for bad in [
            text.replacingOccurrences(of: "Update_rows_partial:", with: "Update_rows:"),
            text.replacingOccurrences(of: "### UPDATE `poc`.`matrix_jsonpartial`", with: "### UPDATE `poc`.`other`"),
            text.replacingOccurrences(of: "### UPDATE ", with: "### INSERT INTO "),
            text.replacingOccurrences(of: "GTID_NEXT= 'uuid:2'", with: "GTID_NEXT= 'uuid:3'"),
            text.replacingOccurrences(
                of: "JSON_REPLACE(@2, '$.a[1]', 123.45)", with: "'{\"text\": \"JSON_REPLACE(\"}'"),
            text.replacingOccurrences(of: "### SET", with: "### WHERE"),
            text.replacingOccurrences(of: "# at 200", with: "# at 400"),
            text.replacingOccurrences(of: "end_log_pos 369", with: "end_log_pos 401"),
            text.replacingOccurrences(of: "end_log_pos 369", with: "end_log_pos 199"),
            text.replacingOccurrences(of: "# at 200", with: "# at bad"),
            text + "\n# at 300\nSET @@SESSION.GTID_NEXT= 'uuid:3'/*!*/;",
        ] { XCTAssertThrowsError(try check.verify(bad, result: result())) }
    }
    func testMultipleUpdatesAndEventsCannotHideInOneProof() {
        for extra in [
            "### UPDATE `poc`.`matrix_jsonpartial`", "# at 300\n# end_log_pos 350 Update_rows_partial: table id 103",
        ] {
            XCTAssertThrowsError(try check.verify(text + "\n" + extra, result: result()))
        }
    }
    func testWindowsRequireOneMatchingWriteOneGTIDAndNoRotation() {
        XCTAssertThrowsError(try check.window([]))
        XCTAssertThrowsError(try check.window([result(), result()]))
        for bad in [result(file: "binlog.000004"), result(start: 400), result(start: 401), result(gtids: "uuid:2-3")] {
            XCTAssertThrowsError(try check.window([bad]))
        }
        let other = LabJSONDiff.Check(writeID: "other", table: check.table, operation: .replace)
        XCTAssertThrowsError(try other.window([result()]))
    }
}
