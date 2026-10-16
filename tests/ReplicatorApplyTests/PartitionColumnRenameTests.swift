import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class PartitionColumnRenameTests: XCTestCase {
    func parse(_ sql: String) throws -> DDLStatement {
        try .parse(
            .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()),
            profile: .mysql57To57InnoDB)
    }
    func table(_ suffix: String) throws -> ApplyTable {
        guard case .create(let table, _) = try parse("CREATE TABLE t(a INT,b INT,n INT,PRIMARY KEY(a,b)) " + suffix)
        else { throw ApplyError("expected table") }
        return table
    }
    func actions(_ clauses: String) throws -> [AlterAction] {
        switch try parse("ALTER TABLE t " + clauses) {
        case .alter(_, let actions): return actions
        case .dropColumn(_, let name): return [.drop(name)]
        default: throw ApplyError("expected ALTER")
        }
    }
    func apply(_ table: ApplyTable, _ actions: [AlterAction]) throws -> ApplyTable {
        var result = try AlterColumnLayout.applying(to: table, actions: actions)
        for action in actions { if case .partition(let change) = action { result = try change.applying(to: result) } }
        return result
    }
    let range = "PARTITION BY RANGE(a) (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
    func testRenameAndTrailingPartitionDefinition() throws {
        let before = try table(range)
        let changes = try actions(
            "CHANGE a c INT PARTITION BY RANGE(c) (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
        )
        XCTAssertEqual(changes.count, 2)
        let after = try apply(before, changes)
        XCTAssertEqual(after.columns.map(\.name), ["c", "b", "n"])
        XCTAssertEqual(after.primaryKeyColumns, ["c", "b"])
        XCTAssertEqual(after.partitions.map(\.expression), ["`c`", "`c`"])
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(after)), after)
    }
    func testRemovePartitioningAndColumnDrop() throws {
        let before = try table(range)
        for clauses in [
            "CHANGE a c INT REMOVE PARTITIONING", "CHANGE a c INT,REMOVE PARTITIONING", "DROP a REMOVE PARTITIONING",
        ] {
            let after = try apply(before, actions(clauses))
            XCTAssertTrue(after.partitions.isEmpty)
            XCTAssertFalse(after.columns.contains { $0.name == "a" })
            try after.validate()
        }
    }
    func testSubpartitionAndSimultaneousNamesUseFinalExpressions() throws {
        let before = try table(
            "PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p VALUES LESS THAN MAXVALUE)")
        let changes = try actions(
            "CHANGE a b INT,CHANGE b a INT PARTITION BY RANGE(b) SUBPARTITION BY HASH(a) SUBPARTITIONS 2 (PARTITION p VALUES LESS THAN MAXVALUE)"
        )
        let after = try apply(before, changes)
        XCTAssertEqual(after.primaryKeyColumns, ["b", "a"])
        XCTAssertEqual(after.partitions[0].expression, "`b`")
        XCTAssertEqual(after.partitions[0].subpartitions?.map(\.expression), ["`a`", "`a`"])
        // Dependency decisions use the whole ALTER, not clause order.
        XCTAssertEqual(try apply(before, changes.reversed()), after)
    }
    func testUnchangedPartitionDependenciesAreRejected() throws {
        let before = try table(
            "PARTITION BY RANGE(a) SUBPARTITION BY HASH(b) SUBPARTITIONS 2 (PARTITION p VALUES LESS THAN MAXVALUE)")
        for clauses in ["CHANGE a c INT", "CHANGE b c INT", "DROP a", "DROP b", "CHANGE a c INT,REBUILD PARTITION ALL"]
        {
            XCTAssertThrowsError(try AlterColumnLayout.applying(to: before, actions: actions(clauses))) {
                XCTAssertTrue(String(describing: $0).contains("unchanged partition expression"), String(describing: $0))
            }
        }
        XCTAssertNoThrow(try apply(before, actions("CHANGE n note INT")))
    }
    func testImplicitKeyFollowsRenamedPrimaryKey() throws {
        for method in ["KEY", "LINEAR KEY"] {
            let after = try apply(
                table("PARTITION BY " + method + "() PARTITIONS 2"), actions("CHANGE a b INT,CHANGE b a INT"))
            XCTAssertEqual(after.primaryKeyColumns, ["b", "a"])
            XCTAssertEqual(after.partitions[0].expression, "")
        }
        XCTAssertThrowsError(try apply(table("PARTITION BY KEY(a) PARTITIONS 2"), actions("CHANGE a c INT")))
    }
    func testReplacementDoesNotRewriteExpressionsOrHideBadColumns() throws {
        let before = try table(range)
        let changes = try actions("CHANGE a c INT PARTITION BY RANGE(a) (PARTITION p VALUES LESS THAN MAXVALUE)")
        // The server checks the new expression. It must not be rewritten to c.
        XCTAssertEqual(try apply(before, changes).partitions[0].expression, "`a`")
        for clauses in ["CHANGE absent c INT REMOVE PARTITIONING", "CHANGE a b INT REMOVE PARTITIONING"] {
            XCTAssertThrowsError(try apply(before, actions(clauses)))
        }
        XCTAssertThrowsError(try parse("ALTER TABLE t CHANGE a c INT PARTITION BY RANGE(c)"))
    }
}
