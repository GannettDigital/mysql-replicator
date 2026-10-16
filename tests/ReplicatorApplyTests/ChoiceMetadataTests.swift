import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ChoiceMetadataTests: XCTestCase {
    func testLostLabelsCannotCompareEqualToLiteralQuestionMarks() throws {
        let column = ApplyColumn(
            name: "e", type: "enum('?','?','a')", nullable: false, collation: "utf8mb4_bin", characterSet: "utf8mb4",
            defaultValue: "?")
        let labels = ["😀", "?", "a"]
        let exact = try ChoiceMetadata.resolved(
            column, labels: labels.map { Data($0.utf8) }, display: labels, defaultValue: "😀", defaultOrdinal: 1)
        XCTAssertEqual(exact.type, "enum('😀','?','a')")
        XCTAssertEqual(exact.choiceDefaultOrdinal, 1)
        XCTAssertNotEqual(exact, column)
        XCTAssertEqual(try JSONDecoder().decode(ApplyColumn.self, from: JSONEncoder().encode(exact)), exact)
        let plan = try DMLTablePlan(ApplyTable(database: "poc", table: "t", columns: [exact], primaryKey: "e"))
        var wire = WireColumn(
            interpretation: .unsigned, type: 247, maximumBytes: 0, nullable: false, collation: 46, primaryKey: true,
            name: "e", metadata: Data([247, 1]), labels: labels.map { Data($0.utf8) })
        try plan.validate(wire: [wire])
        wire.labels![0] = Data("?".utf8)
        XCTAssertThrowsError(try plan.validate(wire: [wire]))
    }
    func testRawNonUTF8LabelsAndLegacySchemaShape() throws {
        let column = ApplyColumn(
            name: "e", type: "enum('é','ÿ')", nullable: false, collation: "latin1_bin", characterSet: "latin1")
        let exact = try ChoiceMetadata.resolved(
            column, labels: [Data([0xe9]), Data([0xff])], display: ["é", "ÿ"], defaultValue: nil, defaultOrdinal: nil)
        XCTAssertEqual(try DMLColumnType(exact).labels, [Data([0xe9]), Data([0xff])])
        XCTAssertThrowsError(try column.validate())
        let old = ApplyColumn(
            name: "e", type: "enum('?','a')", nullable: true, collation: "utf8mb4_bin", characterSet: "utf8mb4",
            defaultValue: "?")
        XCTAssertEqual(
            try ChoiceMetadata.resolved(
                old, labels: [Data([63]), Data([97])], display: ["?", "a"], defaultValue: "?", defaultOrdinal: 1), old)
        let legacy = Data(#"{"name":"e","type":"enum('a')","nullable":true,"collation":"utf8mb4_bin"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ApplyColumn.self, from: legacy).choiceLabels)
        var invalid = exact
        invalid.choiceLabels = []
        XCTAssertThrowsError(try invalid.validate())
    }
    func testNumericAndQuotedChoiceDefaultsRemainDistinct() throws {
        for (sql, numeric) in [("2", true), ("'2'", false)] {
            let query = QueryControl(
                database: "poc", sql: Data("CREATE TABLE t(id INT PRIMARY KEY,e ENUM('2','a') DEFAULT \(sql))".utf8),
                errorCode: 0, statusVariables: Data())
            guard case .create(let table, _) = try DDLStatement.parse(query) else { return XCTFail("missing CREATE") }
            XCTAssertEqual(table.columns[1].numericDefaultLiteral == true, numeric)
            XCTAssertEqual(table.columns[1].defaultValue, "2")
        }
    }
    func testSchemaEqualityKeepsDifferentUnicodeBytes() throws {
        let composed = ApplyColumn(
            name: "e", type: "enum('é')", nullable: true, collation: "utf8mb4_bin", defaultValue: "é")
        var decomposed = composed
        decomposed.type = "enum('e\u{0301}')"
        XCTAssertNotEqual(composed, decomposed)
        decomposed.type = composed.type
        decomposed.defaultValue = "e\u{0301}"
        XCTAssertNotEqual(composed, decomposed)
        let empty = ApplyColumn(
            name: "s", type: "set('','x')", nullable: true, collation: "utf8mb4_bin", defaultValue: "")
        let zero = try ChoiceMetadata.resolved(
            empty, labels: [Data(), Data([120])], display: ["", "x"], defaultValue: "", defaultOrdinal: 0)
        let one = try ChoiceMetadata.resolved(
            empty, labels: [Data(), Data([120])], display: ["", "x"], defaultValue: "", defaultOrdinal: 1)
        XCTAssertNotEqual(zero, one)
    }
    func testMetadataLiteralRoundTripPreservesControlsAndQuotes() throws {
        let labels = ["\0\n\r\\'", "😀", "a,b", ""]
        let type = "enum(" + labels.map(ChoiceMetadata.literal).joined(separator: ",") + ")"
        XCTAssertEqual(try DMLColumnType(type).labels, labels.map { Data($0.utf8) })
    }
}
