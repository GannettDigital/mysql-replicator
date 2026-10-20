import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class CharacterSetTransportTests: XCTestCase {
    func testWidthsUseDeclaredEncodingAndValuesRetainBytes() throws {
        for (charset, collation, width) in [
            ("latin1", "latin1_bin", 20000), ("ascii", "ascii_bin", 20000), ("utf8", "utf8_bin", 20000),
            ("utf8mb3", "utf8mb3_bin", 20000), ("utf8mb4", "utf8mb4_bin", 16383),
        ] {
            let column = ApplyColumn(
                name: "v", type: "varchar(\(width))", nullable: true, collation: collation, characterSet: charset)
            try column.validate()
            let type = try DMLColumnType(column)
            XCTAssertEqual(type.maximumBytes, width * (charset.hasPrefix("utf8") ? (charset == "utf8mb4" ? 4 : 3) : 1))
        }
        XCTAssertThrowsError(
            try ApplyColumn(name: "v", type: "varchar(16384)", nullable: true, collation: "utf8mb4_bin").validate())
        try ApplyColumn(name: "v", type: "varbinary(30000)", nullable: true, collation: nil).validate()
        try DMLColumnType("varchar(4)", characterSet: "latin1").validate(.binary(Data([0, 0x80, 0xe9, 0xff])))
        XCTAssertThrowsError(try DMLColumnType("varchar(4)", characterSet: "ascii").validate(.binary(Data([0xff]))))
        try DMLColumnType("varchar(2)", characterSet: "utf8").validate(.text("é中"))
        XCTAssertThrowsError(try DMLColumnType("varchar(2)", characterSet: "utf8").validate(.text("😀")))
        XCTAssertThrowsError(
            try ApplyColumn(name: "v", type: "text", nullable: true, collation: "latin1_bin", characterSet: "ascii")
                .validate())
    }
    func testSQLConvertsRawParametersAndReadsRawBytes() throws {
        let columns = [
            ApplyColumn(
                name: "id", type: "varchar(10)", nullable: false, collation: "latin1_swedish_ci", characterSet: "latin1"
            ), ApplyColumn(name: "v", type: "text", nullable: true, collation: "ascii_bin", characterSet: "ascii"),
        ]
        let table = ApplyTable(database: "poc", table: "t", columns: columns, primaryKey: "id")
        try table.validate()
        let plan = try DMLSQLPlan(table)
        XCTAssertEqual(
            plan.insert, "INSERT INTO `poc`.`t` (`id`,`v`) VALUES (CONVERT(? USING latin1),CONVERT(? USING ascii))")
        XCTAssertEqual(
            plan.insertSQL(expressions: [["?", "NULL"]]),
            "INSERT INTO `poc`.`t` (`id`,`v`) VALUES (CONVERT(? USING latin1),CONVERT(NULL USING ascii))")
        XCTAssertEqual(plan.updateSQL(expressions: ["?", "?"]), plan.update)
        XCTAssertEqual(plan.delete, "DELETE FROM `poc`.`t` WHERE `id`=CONVERT(? USING latin1)")
        XCTAssertEqual(
            plan.select,
            "SELECT CAST(`id` AS BINARY) AS `id`,CAST(`v` AS BINARY) AS `v` FROM `poc`.`t` WHERE `id`=CONVERT(? USING latin1)"
        )
    }
    func testWireCharsetIdentityAcceptsAliasesButNotDifferentCollations() throws {
        let table = ApplyTable(
            database: "poc", table: "t",
            columns: [
                ApplyColumn(
                    name: "id", type: "varchar(10)", nullable: false, collation: "utf8_bin", characterSet: "utf8")
            ], primaryKey: "id")
        let plan = try DMLTablePlan(table)
        func wire(_ collation: UInt32, _ width: UInt32) -> WireColumn {
            WireColumn(
                interpretation: .utf8, type: 15, maximumBytes: width, nullable: false, collation: collation,
                primaryKey: true, name: "id", metadata: Data([UInt8(width), 0]))
        }
        try plan.validate(wire: [wire(83, 30)])
        XCTAssertThrowsError(try plan.validate(wire: [wire(33, 30)]))
        XCTAssertThrowsError(try plan.validate(wire: [wire(83, 40)]))
    }
}
