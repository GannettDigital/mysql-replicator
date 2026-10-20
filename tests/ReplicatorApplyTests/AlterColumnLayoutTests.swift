import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class AlterColumnLayoutTests: XCTestCase {
    func parse(_ sql: String) throws -> DDLStatement {
        try .parse(
            .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()),
            profile: .mysql57To57InnoDB)
    }
    func table(_ fields: String) throws -> ApplyTable {
        guard case .create(let table, _) = try parse("CREATE TABLE t(" + fields + ")") else {
            throw ApplyError("expected CREATE")
        }
        return table
    }
    func actions(_ sql: String) throws -> [AlterAction] {
        guard case .alter(_, let actions) = try parse("ALTER TABLE t " + sql) else {
            throw ApplyError("expected compound ALTER")
        }
        return actions
    }
    func layout(_ fields: String, _ sql: String) throws -> ApplyTable {
        try AlterColumnLayout.applying(to: table(fields), actions: actions(sql))
    }
    func testSwapRetainsOriginalTypesAndKeyIdentities() throws {
        let before = try table("a VARBINARY(20),b VARBINARY(30),PRIMARY KEY(a(5),b(6)),KEY ka(a(7)),UNIQUE kb(b(8))")
        for sql in [
            "CHANGE a b VARBINARY(20),CHANGE b a VARBINARY(30)", "CHANGE b a VARBINARY(30),CHANGE a b VARBINARY(20)",
        ] {
            let after = try AlterColumnLayout.applying(to: before, actions: actions(sql))
            XCTAssertEqual(after.columns.map(\.name), ["b", "a"])
            XCTAssertEqual(after.columns.map(\.type), before.columns.map(\.type))
            XCTAssertEqual(after.columns.map(\.nullable), [false, false])
            XCTAssertEqual(after.primaryKeyColumns, ["b", "a"])
            XCTAssertEqual(after.primaryKeyParts?.map(\.prefix), [5, 6])
            XCTAssertEqual(after.secondaryIndexes.map { $0.parts[0].column }, ["b", "a"])
            XCTAssertEqual(after.secondaryIndexes.map { $0.parts[0].prefix }, [7, 8])
            XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(after)), after)
            try after.validate()
        }
    }
    func testChainAndThreeWaySwapUseOriginalNames() throws {
        let chain = try layout("id INT PRIMARY KEY,a INT,b BIGINT", "CHANGE a b INT,CHANGE b c BIGINT")
        XCTAssertEqual(chain.columns.map(\.name), ["id", "b", "c"])
        let cycle = try layout("a INT PRIMARY KEY,b INT,c INT", "CHANGE c a INT,CHANGE a b INT,CHANGE b c INT")
        XCTAssertEqual(cycle.columns.map(\.name), ["b", "c", "a"])
        XCTAssertEqual(cycle.primaryKeyColumns, ["b"])
    }
    func testPlacementUsesFinalNamesAndOriginalIdentities() throws {
        for (sql, names) in [
            ("CHANGE a b INT AFTER a,CHANGE b a INT", ["id", "a", "b"]),
            ("CHANGE a b INT AFTER id,CHANGE b a INT FIRST", ["a", "id", "b"]),
            ("ADD c INT AFTER b,CHANGE a b INT,CHANGE b a INT", ["id", "b", "c", "a"]),
            ("CHANGE a b INT AFTER c,ADD c INT FIRST,CHANGE b a INT", ["c", "id", "a", "b"]),
        ] {
            // AFTER a new column is valid only when ADD precedes that placement.
            if sql.contains("AFTER c,ADD") {
                XCTAssertThrowsError(try layout("id INT PRIMARY KEY,a INT,b INT", sql))
                continue
            }
            XCTAssertEqual(try layout("id INT PRIMARY KEY,a INT,b INT", sql).columns.map(\.name), names)
        }
        XCTAssertEqual(
            try layout("id INT PRIMARY KEY,a INT,b INT", "ADD c INT FIRST,CHANGE a b INT AFTER c,CHANGE b a INT")
                .columns.map(\.name), ["c", "b", "id", "a"])
    }
    func testDropAndReuseNameDoesNotTransferOldKey() throws {
        let after = try layout("id INT PRIMARY KEY,a INT,b INT,KEY ka(a),KEY kb(b)", "DROP a,CHANGE b a INT")
        XCTAssertEqual(after.columns.map(\.name), ["id", "a"])
        XCTAssertEqual(after.secondaryIndexes.map(\.name), ["kb"])
        XCTAssertEqual(after.secondaryIndexes[0].parts[0].column, "a")
        var explicit = try layout("id INT PRIMARY KEY,a INT,KEY ka(a)", "DROP INDEX ka,DROP a")
        explicit = try IndexChange.drop("ka").applying(to: explicit)
        XCTAssertTrue(explicit.secondaryIndexes.isEmpty)
    }
    func testSelfForeignKeyIsMappedOnce() throws {
        let after = try layout(
            "id INT PRIMARY KEY,pid INT,CONSTRAINT f FOREIGN KEY(pid) REFERENCES t(id)",
            "CHANGE id pid INT,CHANGE pid id INT")
        XCTAssertEqual(after.primaryKeyColumns, ["pid"])
        XCTAssertEqual(after.foreignKeys[0].columns, ["id"])
        XCTAssertEqual(after.foreignKeys[0].referencedColumns, ["pid"])
        XCTAssertEqual(after.secondaryIndexes[0].parts[0].column, "id")
        try after.validate()
    }
    func testInvalidOriginalAndFinalNamesAreRejected() throws {
        for sql in [
            "CHANGE a b INT,CHANGE a c INT", "CHANGE a b INT,CHANGE missing c INT", "CHANGE a b INT,ADD c INT",
            "DROP a,CHANGE a c INT", "DROP a,DROP a", "CHANGE a b INT,CHANGE b a INT,ALTER a SET DEFAULT 7",
            "CHANGE a b INT AFTER b,CHANGE b a INT",
        ] {
            XCTAssertThrowsError(try layout("id INT PRIMARY KEY,a INT,b INT", sql), sql)
        }
    }
    func testDependentExpressionsNeedExplicitReplacement() throws {
        let before = try table("id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED")
        let rules = NativeReplicationRules(profile: .mysql57To57InnoDB)
        XCTAssertThrowsError(
            try ColumnExpressionDependencies.validate(
                before, actions: actions("CHANGE a b INT,CHANGE b a INT"), rules: rules))
        let edits = try actions("CHANGE a b INT,CHANGE b a INT,MODIFY g INT GENERATED ALWAYS AS(b+1) STORED")
        try ColumnExpressionDependencies.validate(before, actions: edits, rules: rules)
        let after = try AlterColumnLayout.applying(to: before, actions: edits)
        XCTAssertEqual(after.columns.map(\.name), ["id", "b", "a", "g"])
        XCTAssertEqual(after.columns.last?.generationExpression, "(`b` + 1)")
    }
}
