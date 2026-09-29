import XCTest
@testable import ReplicatorLabCore

final class BinlogReferenceTests: XCTestCase {
    // Hand-authored mysqlbinlog-shaped input; expected values are not obtained
    // from either the Rust codec or the normalizer under test.
    let input = """
    # at 10
    ### INSERT INTO ~poc~.~items~
    ### SET
    ###   @1=3 /* INT meta=0 nullable=0 is_null=0 */
    ###   @2='inserted' /* VARSTRING(400) meta=400 nullable=0 is_null=0 */
    ###   @3=-1 (18446744073709551615) /* LONGINT meta=0 nullable=0 is_null=0 */
    # at 100
    ### UPDATE ~poc~.~items~
    ### WHERE
    ###   @1=3 /* INT */
    ###   @2='inserted' /* VARSTRING */
    ###   @3=-1 (18446744073709551615) /* LONGINT */
    ### SET
    ###   @1=3 /* INT */
    ###   @2='final-three' /* VARSTRING */
    ###   @3=9 /* LONGINT */
    # at 200
    """
    var rendered: String { input.replacingOccurrences(of: "~", with: String(UnicodeScalar(96)!)) }
    func testExactUnsignedValuesAndBeforeAfterImages() throws {
        let operations = try BinlogReference.parse(rendered, from: 10)
        XCTAssertEqual(operations, [
            RowOperation("insert", after: ["3", "inserted", "18446744073709551615"]),
            RowOperation("update", before: ["3", "inserted", "18446744073709551615"], after: ["3", "final-three", "9"])
        ])
    }
    func testBoundariesExcludeSeedAndProbeTraffic() throws {
        XCTAssertEqual(try BinlogReference.parse(rendered, from: 100, before: 200).count, 1)
        XCTAssertEqual(try BinlogReference.parse(rendered, from: 10, before: 100).count, 1)
        XCTAssertEqual(try BinlogReference.parse(rendered, from: 200).count, 0)
    }
    func testTruncatedOrUnknownRowsAndInconsistentUnsignedAreRejected() {
        let bad = [
            rendered.replacingOccurrences(of: "###   @2='inserted' /* VARSTRING(400) meta=400 nullable=0 is_null=0 */", with: ""),
            rendered.replacingOccurrences(of: "@3=-1 (18446744073709551615)", with: "@3=-1 (18446744073709551614)"),
            rendered.replacingOccurrences(of: "@1=3", with: "@4=3"),
            rendered.replacingOccurrences(of: "'inserted'", with: "'unqualified\\ntext'"),
            rendered.replacingOccurrences(of: "### SET", with: "### UNKNOWN")
        ]
        for input in bad { XCTAssertThrowsError(try BinlogReference.parse(input, from: 10)) }
    }
    func testRecordedMySQLReferenceCorpus() throws {
        let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        XCTAssertEqual(manifest.count, 3)
        for entry in manifest {
            let input = try String(contentsOf: directory.appendingPathComponent(entry["text"] as! String), encoding: .utf8)
            let start = (entry["start"] as! NSNumber).uint64Value
            let end = (entry["end"] as! NSNumber).uint64Value
            let expected = entry["outcome"] as! String == "rejected_1837" ? Array(Fixture.operations.prefix(1)) : Fixture.operations
            try Comparison.operations(BinlogReference.parse(input, from: start, before: end), expected: expected)
        }
    }
}
