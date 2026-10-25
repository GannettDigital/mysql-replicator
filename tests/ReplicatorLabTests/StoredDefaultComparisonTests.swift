import XCTest

@testable import ReplicatorLabCore

final class StoredDefaultComparisonTests: XCTestCase {
    private func column(
        _ name: String, type: String = "varchar(10)", nullable: String = "YES",
        table: String = "t", value: String = "<stored-default>"
    ) -> [String] {
        [table, name, "1", type, nullable, "utf8mb4", "utf8mb4_bin", value, "", ""]
    }

    func testNullableDefaultsKeepExactBytesAndMetadata() throws {
        let input = [
            column("id", type: "int", value: "<NULL>"), column("a`b"),
            column("binary", type: "binary(4)"), column("empty", type: "varbinary(4)"),
            column("wide", type: "char(4)", table: "t`é"),
        ]
        var calls = 0
        let result = try LabStoredDefaultComparison.columns(input, database: "db`é") { queries in
            calls += 1
            XCTAssertEqual(queries.map(\.name), ["default-1", "default-2", "default-3", "default-4"])
            XCTAssertTrue(queries.allSatisfy(\.preserveWhitespace))
            XCTAssertEqual(
                queries[0].sql,
                "SET NAMES utf8mb4; SELECT HEX(CONVERT(DEFAULT(t.`a``b`) USING utf8mb4)) FROM `db``é`.`t` AS t RIGHT JOIN (SELECT 1) AS p ON FALSE LIMIT 1"
            )
            XCTAssertEqual(
                queries[1].sql,
                "SET NAMES utf8mb4; SELECT HEX(DEFAULT(t.`binary`)) FROM `db``é`.`t` AS t RIGHT JOIN (SELECT 1) AS p ON FALSE LIMIT 1"
            )
            XCTAssertTrue(queries[3].sql.contains("CONVERT(DEFAULT(t.`wide`) USING utf8mb4)"))
            XCTAssertTrue(queries[3].sql.contains("FROM `db``é`.`t``é`"))
            return [
                "default-4": "C3A92020", "default-2": "FF000000", "default-1": "6500", "default-3": "",
            ]
        }
        var expected = input
        for (index, value) in [(1, "6500"), (2, "FF000000"), (3, ""), (4, "C3A92020")] {
            expected[index][7] = "X'" + value + "'"
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(calls, 1)
    }

    func testNotNullDefaultsUseUnloggedTemporaryClonesAndDropEach() throws {
        var temporaryNames: Set<String> = []
        let input = [column("a`b", nullable: "NO"), column("b", type: "varbinary(4)", nullable: "NO")]
        let result = try LabStoredDefaultComparison.columns(input, database: "db") { queries in
            XCTAssertEqual(queries.count, 2)
            for (index, query) in queries.enumerated() {
                XCTAssertTrue(
                    query.sql.hasPrefix("SET NAMES utf8mb4; SET sql_log_bin=0; CREATE TEMPORARY TABLE "))
                let range = try XCTUnwrap(
                    query.sql.range(of: #"_lab_default_[0-9A-F]{32}"#, options: .regularExpression))
                let temporary = "`db`.`" + query.sql[range] + "`"
                temporaryNames.insert(temporary)
                XCTAssertEqual(query.sql.components(separatedBy: temporary).count - 1, 4)
                XCTAssertTrue(
                    query.sql.contains(
                        " ENGINE=InnoDB AS SELECT " + (index == 0 ? "`a``b`" : "`b`")
                            + " AS v FROM `db`.`t` LIMIT 0; INSERT INTO " + temporary + " VALUES(DEFAULT);"))
                XCTAssertTrue(
                    query.sql.contains(index == 0 ? "SELECT HEX(CONVERT(v USING utf8mb4))" : "SELECT HEX(v)"))
                XCTAssertTrue(query.sql.hasSuffix("; DROP TEMPORARY TABLE " + temporary))
            }
            return ["default-0": "73656564", "default-1": "00FF"]
        }
        XCTAssertEqual(temporaryNames.count, 2)
        XCTAssertEqual(result.map { $0[7] }, ["X'73656564'", "X'00FF'"])
    }

    func testEachComparisonReadsDefaultsAgain() throws {
        let input = [column("v")]
        var next = "41"
        var calls = 0
        func run() throws -> [[String]] {
            try LabStoredDefaultComparison.columns(input, database: "db") { _ in
                calls += 1
                return ["default-0": next]
            }
        }
        XCTAssertEqual(try run()[0][7], "X'41'")
        next = "42"
        XCTAssertEqual(try run()[0][7], "X'42'")
        XCTAssertEqual(calls, 2)
    }

    func testQueryCountBoundKeepsEveryColumn() throws {
        let input = (0..<65).map { column("v\($0)") }
        var batches: [Int] = []
        var names: [String] = []
        let result = try LabStoredDefaultComparison.columns(input, database: "db") { queries in
            batches.append(queries.count)
            names += queries.map(\.name)
            return Dictionary(uniqueKeysWithValues: queries.map { ($0.name, "41") })
        }
        XCTAssertEqual(batches, [32, 32, 1])
        XCTAssertEqual(names, (0..<65).map { "default-\($0)" })
        XCTAssertEqual(result.map { $0[7] }, Array(repeating: "X'41'", count: 65))
    }

    func testSQLByteBoundAndOversizedQuery() throws {
        for length in [150_000, 300_000] {
            let input = (0..<3).map { column("v\($0)", table: String(repeating: "t", count: length)) }
            var calls = 0
            _ = try LabStoredDefaultComparison.columns(input, database: "db") { queries in
                calls += 1
                XCTAssertEqual(queries.count, 1)
                XCTAssertEqual(queries[0].sql.utf8.count > 256 * 1024, length == 300_000)
                return [queries[0].name: "41"]
            }
            XCTAssertEqual(calls, 3)
        }
    }

    func testNoProbesForAbsentStoredDefaults() throws {
        for input in [[], [column("v", value: "<NULL>"), column("n", type: "int", value: "7")]] {
            XCTAssertEqual(
                try LabStoredDefaultComparison.columns(input, database: "db") { _ in
                    XCTFail("unexpected default probe")
                    return [:]
                }, input)
        }
    }

    func testMalformedAndIncompleteRepliesFail() {
        for values in [
            [:], ["wrong": "41"], ["default-0": "41", "extra": "42"],
            ["default-0": "NULL"], ["default-0": "F"], ["default-0": "ff"],
            ["default-0": "41\n42"], ["default-0": "41\n"], ["default-0": "41\t42"], ["default-0": " 41"],
        ] {
            XCTAssertThrowsError(
                try LabStoredDefaultComparison.columns([column("v")], database: "db") { _ in values })
        }
    }

    func testClientFailureStopsFurtherBatches() {
        var calls = 0
        XCTAssertThrowsError(
            try LabStoredDefaultComparison.columns((0..<65).map { column("v\($0)") }, database: "db") {
                _ in
                calls += 1
                throw LabError("client failure")
            })
        XCTAssertEqual(calls, 1)
    }
}
