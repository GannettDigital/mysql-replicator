import XCTest

@testable import ReplicatorLabCore

final class ReverseSchemaComparisonTests: XCTestCase {
    func testCharsetAliasesDoNotRewriteLiteralDefaults() throws {
        let old = ["t", "c", "1", "varchar(20)", "YES", "utf8", "utf8_bin", "utf8_general_ci", "", ""].joined(
            separator: "\t")
        let expected = ["t", "c", "1", "varchar(20)", "YES", "utf8mb3", "utf8mb3_bin", "utf8_general_ci", "", ""]
            .joined(separator: "\t")
        XCTAssertEqual(try ReverseSchemaComparison.columns(old, mysql84: false), expected)
        XCTAssertEqual(try ReverseSchemaComparison.columns(expected, mysql84: true), expected)
    }
    func testPartitionIdentifierQuotingDoesNotChangeBounds() throws {
        XCTAssertEqual(try ReverseSchemaComparison.partitions("t\tp0\tHASH\t`id`\t"), "t\tp0\tHASH\tid\t")
        XCTAssertEqual(
            try ReverseSchemaComparison.partitions("t\tp0\tRANGE COLUMNS\t`day`, `id`\t'`literal`'"),
            "t\tp0\tRANGE COLUMNS\tday,id\t'`literal`'")
    }
    func testPartitionFunctionSpellingDoesNotHideOtherDifferences() throws {
        func row(_ expression: String, _ bound: String = "739982") -> String {
            "t\tp\tRANGE\t" + expression + "\t" + bound
        }
        for (source, target) in [
            ("TO_DAYS(d)", "to_days(`d`)"), ("EXTRACT(YEAR_MONTH FROM d)", "extract(year_month from `d`)"),
        ] {
            XCTAssertEqual(
                try ReverseSchemaComparison.partitions(row(source)), try ReverseSchemaComparison.partitions(row(target))
            )
        }
        for expression in ["TO_DAYS('UPPER')", "TO_DAYS(d+1)", "TO_DAYS((d))", "TO_DAYS(other)"] {
            XCTAssertNotEqual(
                try ReverseSchemaComparison.partitions(row(expression)),
                try ReverseSchemaComparison.partitions(row("to_days(`d`)")))
        }
        XCTAssertNotEqual(
            try ReverseSchemaComparison.partitions(row("TO_DAYS(d)", "'UPPER'")),
            try ReverseSchemaComparison.partitions(row("TO_DAYS(d)", "'upper'")))
        XCTAssertNotEqual(
            try ReverseSchemaComparison.partitions(row("TO_DAYS(D)")),
            try ReverseSchemaComparison.partitions(row("TO_DAYS(d)")))
    }
    func testMetadataNormalizationPreservesLiterals() throws {
        func row(_ type: String, _ value: String, _ extra: String = "") -> String {
            ["t", "c", "1", type, "YES", "", "", value, extra, ""].joined(separator: "\t")
        }
        let literal = row("varchar(50)", "int(11) current_timestamp DEFAULT_GENERATED")
        XCTAssertEqual(try ReverseSchemaComparison.columns(literal, mysql84: true), literal)
        let labels = row("enum('int(11)','current_timestamp')", "current_timestamp")
        XCTAssertEqual(try ReverseSchemaComparison.columns(labels, mysql84: true), labels)
        XCTAssertEqual(try ReverseSchemaComparison.columns(row("int(11)", "7"), mysql84: false), row("int", "7"))
        for mysql84 in [false, true] {
            let padded = row("int(8) unsigned zerofill", "00000007")
            XCTAssertEqual(try ReverseSchemaComparison.columns(padded, mysql84: mysql84), padded)
        }
        XCTAssertEqual(
            try ReverseSchemaComparison.columns(row("binary(5)", "X'FF00010000'"), mysql84: true),
            row("binary(5)", "X'FF00010000'"))
        XCTAssertEqual(
            try ReverseSchemaComparison.columns(
                row("timestamp", "current_timestamp()", "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"), mysql84: true),
            row("timestamp", "CURRENT_TIMESTAMP", "on update CURRENT_TIMESTAMP"))
    }
    func testKnownGeneratedMetadataSpellingsDoNotRewriteOtherExpressions() throws {
        func row(_ expression: String) -> String {
            ["t", "v", "1", "int", "YES", "", "", "<NULL>", "STORED GENERATED", expression].joined(separator: "\t")
        }
        for (source, target) in [
            ("(`n` is null)", "isnull(`n`)"), ("_utf8mb4\\'`a`\\'", "'`a`'"),
            ("trim(both _utf8mb4\\'x\\' from `v`)", "trim(both 'x' from `v`)"),
        ] {
            XCTAssertEqual(try ReverseSchemaComparison.columns(row(source), mysql84: true), row(target))
            XCTAssertEqual(try ReverseSchemaComparison.columns(row(source), mysql84: false), row(source))
        }
        for expression in [
            "_utf8mb4\\'`b`\\'", "'(`n` is null)'", "trim(both _utf8mb4\\'y\\' from `v`)", "(`other` is null)",
        ] {
            XCTAssertEqual(try ReverseSchemaComparison.columns(row(expression), mysql84: true), row(expression))
        }
    }

}
