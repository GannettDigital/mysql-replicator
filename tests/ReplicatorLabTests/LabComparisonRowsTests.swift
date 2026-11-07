import XCTest

@testable import ReplicatorLabCore

final class LabComparisonRowsTests: XCTestCase {
    func testReadsOnceAndBatchesJSONAcrossTablesWithoutLosingEmptyValues() throws {
        let tables: [LabComparisonRows.Table] = [
            .init(name: "j`a", columns: ["id", "doc"], jsonColumns: ["doc"], orderBy: "`id`"),
            .init(name: "empty", columns: ["v"], jsonColumns: [], orderBy: "`v`"),
            .init(name: "other", columns: ["__comparison_row__"], jsonColumns: ["__comparison_row__"], orderBy: "1"),
            .init(name: "no_rows", columns: ["v"], jsonColumns: [], orderBy: "`v`"),
        ]
        var calls = 0
        let result = try LabComparisonRows.read(database: "d`b", tables: tables) { queries in
            calls += 1
            XCTAssertTrue(queries.allSatisfy(\.preserveWhitespace))
            if calls == 1 {
                XCTAssertEqual(queries.map(\.name), ["rows-0", "rows-1", "rows-2", "rows-3"])
                XCTAssertTrue(queries[0].sql.contains("SELECT 1,IFNULL(HEX(CAST(`id` AS BINARY))"))
                XCTAssertTrue(queries[0].sql.hasSuffix(" FROM `d``b`.`j``a` ORDER BY `id`"))
                return ["rows-0": "1\t31\t6E756C6C\n1\t32\t<NULL>", "rows-1": "1\t\n1\t",
                    "rows-2": "1\t312E3030", "rows-3": ""]
            }
            XCTAssertEqual(queries.map(\.name), ["json-0-0", "json-1-0"])
            XCTAssertTrue(queries[0].sql.hasSuffix(" FROM `d``b`.`j``a` ORDER BY `id` LIMIT 1 OFFSET 0"))
            XCTAssertTrue(queries[1].sql.contains("JSON_EXTRACT(`__comparison_row__`,"))
            return ["json-0-0": "NULL\t6E756C6C", "json-1-0": "DECIMAL\t312E3030"]
        }
        let null = try JSONSerialization.data(withJSONObject: [["$", "NULL", "6E756C6C"]]).base64EncodedString()
        let decimal = try JSONSerialization.data(withJSONObject: [["$", "DECIMAL", "312E3030"]]).base64EncodedString()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result, "j`a\t31\t\(null)\nj`a\t32\t<NULL>\nempty\t\nempty\t\nother\t\(decimal)")
    }

    func testTableNamesRetainExactUnicodeBytes() throws {
        let names = ["\u{00e9}", "e\u{0301}"]
        let result = try LabComparisonRows.read(database: "db", tables: names.map {
            .init(name: $0, columns: ["v"], jsonColumns: [], orderBy: "`v`")
        }) { queries in
            XCTAssertEqual(queries.count, 2)
            XCTAssertTrue(queries[0].sql.utf8.contains(0xc3))
            XCTAssertTrue(queries[1].sql.utf8.contains(0xcc))
            return ["rows-0": "1\t31", "rows-1": "1\t32"]
        }
        XCTAssertTrue(LabSQLName.equal(result, names[0] + "\t31\n" + names[1] + "\t32"))
    }

    func testRawBatchesAreBoundedAndKeepTableOrder() throws {
        var sizes: [Int] = []
        let tables = (0..<65).map { LabComparisonRows.Table(name: "t\($0)", columns: ["v"], jsonColumns: [], orderBy: "`v`") }
        let result = try LabComparisonRows.read(database: "db", tables: tables) { queries in
            sizes.append(queries.count)
            return Dictionary(uniqueKeysWithValues: queries.map { ($0.name, "1\t00") })
        }
        XCTAssertEqual(sizes, [32, 32, 1])
        XCTAssertEqual(result.components(separatedBy: "\n"), (0..<65).map { "t\($0)\t00" })
    }

    func testRawSQLByteBoundAndSingleOversizedQuery() throws {
        for size in [140_000, 280_000] {
            var sizes: [Int] = []
            _ = try LabComparisonRows.read(database: "db", tables: (0..<3).map {
                .init(name: "t\($0)", columns: ["v"], jsonColumns: [], orderBy: String(repeating: "1,", count: size / 2) + "1")
            }) { queries in
                sizes.append(queries.count)
                XCTAssertEqual(queries.count, 1)
                XCTAssertEqual(queries[0].sql.utf8.count > 256 * 1024, size == 280_000)
                return [queries[0].name: "1\t00"]
            }
            XCTAssertEqual(sizes, [1, 1, 1])
        }
    }

    func testMissingExtraAndMalformedRowsFailBeforeJSONInspection() {
        for result in [
            [:], ["wrong": ""], ["rows-0": "", "extra": ""], ["rows-0": "1"],
            ["rows-0": "2\t<NULL>"], ["rows-0": "1\t<NULL>\textra"],
        ] {
            var calls = 0
            XCTAssertThrowsError(try LabComparisonRows.read(database: "db", tables: [
                .init(name: "t", columns: ["j"], jsonColumns: ["j"], orderBy: "1")
            ]) { _ in
                calls += 1
                return result
            })
            XCTAssertEqual(calls, 1)
        }
    }

    func testEmptySelectionMakesNoCallAndErrorsStopTheRead() throws {
        XCTAssertEqual(try LabComparisonRows.read(database: "db", tables: []) { _ in
            XCTFail("unexpected query"); return [:]
        }, "")
        var calls = 0
        XCTAssertThrowsError(try LabComparisonRows.read(database: "db", tables: (0..<65).map {
            .init(name: "t\($0)", columns: ["v"], jsonColumns: [], orderBy: "`v`")
        }) { _ in
            calls += 1
            throw LabError("client failed")
        })
        XCTAssertEqual(calls, 1)
    }
}
