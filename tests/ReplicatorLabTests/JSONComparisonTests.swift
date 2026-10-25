import XCTest

@testable import ReplicatorLabCore

final class JSONComparisonTests: XCTestCase {
    private func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02X", $0) }.joined()
    }

    private func encoded(_ nodes: [[String]]) throws -> String {
        try JSONSerialization.data(withJSONObject: nodes).base64EncodedString()
    }

    func testBatchMapsMultipleRowsAndColumnsWithoutChangingOtherValues() throws {
        let raw = [
            ["31", hex("null"), hex(#""""#)],
            ["32", "<NULL>", hex("{}")],
            ["33", hex("1.00"), hex("\"2024-02-29\"")],
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n")
        var calls = 0
        let result = try LabJSONComparison.rows(
            raw, columns: ["id", "j`", "other"], jsonColumns: ["j`", "other"],
            from: " FROM `db`.`t` ORDER BY `id`"
        ) { queries in
            calls += 1
            XCTAssertEqual(queries.map(\.name), (0..<5).map { "json-\($0)-0" })
            XCTAssertTrue(queries.allSatisfy(\.preserveWhitespace))
            XCTAssertTrue(queries[0].sql.contains("JSON_EXTRACT(`j```,CONVERT(0x24 USING utf8mb4))"))
            for (query, row) in zip(queries, [0, 0, 1, 2, 2]) {
                XCTAssertTrue(query.sql.hasSuffix(" FROM `db`.`t` ORDER BY `id` LIMIT 1 OFFSET \(row)"))
                XCTAssertTrue(query.sql.hasPrefix("SET NAMES utf8mb4; SET time_zone='+00:00'; SELECT "))
            }
            return Dictionary(
                uniqueKeysWithValues: zip(
                    queries.map(\.name),
                    [
                        "NULL\t6E756C6C", "STRING\t", "OBJECT\t7B7D", "DECIMAL\t312E3030", "DATE\t323032342D30322D3239",
                    ]))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(
            result,
            try [
                ["31", encoded([["$", "NULL", "6E756C6C"]]), encoded([["$", "STRING", ""]])],
                ["32", "<NULL>", encoded([["$", "OBJECT", ""]])],
                ["33", encoded([["$", "DECIMAL", "312E3030"]]), encoded([["$", "DATE", "323032342D30322D3239"]])],
            ].map { $0.joined(separator: "\t") }.joined(separator: "\n"))
    }

    func testPathsAcrossChunksRetainOrder() throws {
        let text = "[" + Array(repeating: "0", count: 33).joined(separator: ",") + "]"
        let result = try LabJSONComparison.rows(hex(text), columns: ["j"], jsonColumns: ["j"], from: " FROM t") {
            queries in
            XCTAssertEqual(queries.map(\.name), ["json-0-0", "json-0-32"])
            XCTAssertEqual(queries.map { $0.sql.components(separatedBy: "JSON_TYPE(").count - 1 }, [32, 2])
            XCTAssertTrue(queries[1].sql.contains("0x245b33315d"))  // $[31]
            return [
                "json-0-0": (["ARRAY", "5B5D"] + Array(repeating: ["INTEGER", "30"], count: 31).flatMap { $0 })
                    .joined(separator: "\t"),
                "json-0-32": "INTEGER\t30\tINTEGER\t30",
            ]
        }
        XCTAssertEqual(
            result, try encoded([["$", "ARRAY", ""]] + (0..<33).map { ["$[\($0)]", "INTEGER", "30"] }))
    }

    func testQueryCountBoundPreservesDuplicateRows() throws {
        var sizes: [Int] = []
        var names: [String] = []
        let result = try LabJSONComparison.rows(
            Array(repeating: hex("null"), count: 65).joined(separator: "\n"),
            columns: ["j"], jsonColumns: ["j"], from: " FROM t"
        ) { queries in
            sizes.append(queries.count)
            names += queries.map(\.name)
            return Dictionary(uniqueKeysWithValues: queries.map { ($0.name, "NULL\t6E756C6C") })
        }
        XCTAssertEqual(sizes, [32, 32, 1])
        XCTAssertEqual(names, (0..<65).map { "json-\($0)-0" })
        XCTAssertEqual(
            result.components(separatedBy: "\n"), try Array(repeating: encoded([["$", "NULL", "6E756C6C"]]), count: 65))
    }

    func testSQLByteBoundAndOversizedSingleQuery() throws {
        for keyLength in [40_000, 80_000] {
            let text = "{\"" + String(repeating: "x", count: keyLength) + "\":null}"
            var sizes: [Int] = []
            _ = try LabJSONComparison.rows(
                Array(repeating: hex(text), count: 3).joined(separator: "\n"),
                columns: ["j"], jsonColumns: ["j"], from: " FROM t"
            ) { queries in
                sizes.append(queries.count)
                XCTAssertEqual(queries.count, 1)
                XCTAssertEqual(queries[0].sql.utf8.count > 256 * 1024, keyLength == 80_000)
                return [queries[0].name: "OBJECT\t7B7D\tNULL\t6E756C6C"]
            }
            XCTAssertEqual(sizes, [1, 1, 1])
        }
    }

    func testNoInspectionForEmptyRowsSQLNullOrNonJSONColumns() throws {
        for (raw, columns) in [("", ["j"]), ("<NULL>", ["j"]), ("3132", [])] {
            let result = try LabJSONComparison.rows(raw, columns: ["j"], jsonColumns: columns, from: " FROM t") { _ in
                XCTFail("unexpected inspection")
                return [:]
            }
            XCTAssertEqual(result, raw)
        }
    }

    func testMissingExtraTruncatedAndMultipleRowResultsFail() {
        for result in [
            [:], ["wrong": "NULL\t6E756C6C"], ["json-0-0": "NULL\t6E756C6C", "extra": ""],
            ["json-0-0": "NULL"], ["json-0-0": "NULL\tNULL"],
            ["json-0-0": "NULL\t6E756C6C\nNULL\t6E756C6C"],
        ] {
            XCTAssertThrowsError(
                try LabJSONComparison.rows(hex("null"), columns: ["j"], jsonColumns: ["j"], from: " FROM t") { _ in
                    result
                })
        }
        XCTAssertThrowsError(
            try LabJSONComparison.rows("00\t00", columns: ["j"], jsonColumns: ["j"], from: " FROM t") { _ in
                XCTFail("invalid row must fail before querying")
                return [:]
            })
    }

    func testClientErrorStopsRemainingBatches() {
        var calls = 0
        XCTAssertThrowsError(
            try LabJSONComparison.rows(
                Array(repeating: hex("null"), count: 65).joined(separator: "\n"),
                columns: ["j"], jsonColumns: ["j"], from: " FROM t"
            ) { _ in
                calls += 1
                throw LabError("client failed")
            })
        XCTAssertEqual(calls, 1)
    }

    func testPathsKeepArrayOrderAndEscapedObjectKeys() throws {
        XCTAssertEqual(
            try LabJSONComparison.paths(#"{"z":[],"a\"b":[null,{"n":18446744073709551615}]}"#),
            ["$", #"$."a\"b""#, #"$."a\"b"[0]"#, #"$."a\"b"[1]"#, #"$."a\"b"[1]."n""#, #"$."z""#])
        XCTAssertEqual(try LabJSONComparison.paths("null"), ["$"])
    }
    func testOnlyDoubleDisplayIsNormalized() throws {
        func value(_ type: String, _ text: String) throws -> String {
            try LabJSONComparison.scalar(type, text.utf8.map { String(format: "%02X", $0) }.joined())
        }
        XCTAssertEqual(try value("DOUBLE", "1"), try value("DOUBLE", "1.0"))
        XCTAssertNotEqual(try value("DOUBLE", "1.0"), try value("DOUBLE", "1.0000000000000002"))
        XCTAssertNotEqual(try value("DECIMAL", "1.00"), try value("DECIMAL", "1"))
        XCTAssertNotEqual(try value("STRING", "1.0"), try value("STRING", "1"))
        XCTAssertNotEqual(
            try value("UNSIGNED INTEGER", "18446744073709551615"), try value("UNSIGNED INTEGER", "18446744073709551614")
        )
        XCTAssertNotEqual(try value("DOUBLE", "1"), try value("INTEGER", "1"))
        XCTAssertEqual(try value("NULL", "null"), "6E756C6C")
        XCTAssertThrowsError(try LabJSONComparison.scalar("NULL", "NULL"))
        XCTAssertThrowsError(try value("DOUBLE", "not-a-number"))
    }
}
