import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class EnumZeroWriteTests: XCTestCase {
    func testStrictModeIsRestoredAfterSuccessAndFailure() throws {
        for fail in [false, true] {
            var modes: [String] = []
            let operation = {
                try EnumZeroWrite.withMode(
                    required: true, setMode: { modes.append($0) }, discardConnection: { XCTFail("unexpected discard") }
                ) {
                    XCTAssertEqual(modes, [EnumZeroWrite.writeMode])
                    if fail {
                        throw ApplyError("duplicate", code: .duplicateKey, mysqlErrorNumber: 1062, sqlState: "23000")
                    }
                    return 7
                }
            }
            if fail {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual(($0 as? ApplyError)?.mysqlErrorNumber, 1062) }
            } else {
                XCTAssertEqual(try operation(), 7)
            }
            XCTAssertEqual(modes, [EnumZeroWrite.writeMode, EnumZeroWrite.strictMode])
        }
    }
    func testFailedRestoreClosesConnectionAndCannotBeSkippedAsDuplicate() throws {
        var discarded = false
        XCTAssertThrowsError(
            try EnumZeroWrite.withMode(
                required: true,
                setMode: { mode in
                    if mode == EnumZeroWrite.strictMode { throw ApplyError("restore failed") }
                }, discardConnection: { discarded = true }
            ) {
                throw ApplyError("duplicate", code: .duplicateKey, mysqlErrorNumber: 1062, sqlState: "23000")
            }
        ) { error in
            XCTAssertNil((error as? ApplyError)?.mysqlErrorNumber)
            XCTAssertTrue(String(describing: error).contains("cannot restore strict SQL mode"))
        }
        XCTAssertTrue(discarded)
    }
    func testOrdinaryWritesAndDeletesDoNotChangeSQLMode() throws {
        let table = ApplyTable(
            database: "poc", table: "t",
            columns: [
                ApplyColumn(name: "id", type: "int", nullable: false, collation: nil),
                ApplyColumn(name: "e", type: "enum('','a')", nullable: true, collation: "utf8mb4_bin"),
            ], primaryKey: "id")
        XCTAssertTrue(EnumZeroWrite.required(table: table, after: [.signed(1), .unsigned(0)]))
        XCTAssertFalse(EnumZeroWrite.required(table: table, after: [.signed(0), .unsigned(1)]))
        XCTAssertFalse(EnumZeroWrite.required(table: table, after: [.signed(0), .null]))
        XCTAssertFalse(EnumZeroWrite.required(table: table, after: nil))
        XCTAssertEqual(
            try EnumZeroWrite.withMode(
                required: false, setMode: { _ in XCTFail("ordinary write changed mode") },
                discardConnection: { XCTFail("discard") }
            ) { 42 }, 42)
        let plan = try DMLSQLPlan(table)
        XCTAssertTrue(plan.insert.hasPrefix("INSERT INTO "))
        XCTAssertFalse(plan.insert.contains("IGNORE"))
    }
}

extension ApplyTests {
    func testInnoDBEnumZeroResultCheckCanRollBack() throws {
        let table = ApplyTable(
            database: "poc", table: "t",
            columns: [
                ApplyColumn(name: "id", type: "int", nullable: false, collation: nil),
                ApplyColumn(name: "e", type: "enum('','a')", nullable: true, collation: "utf8mb4_bin"),
            ], primaryKey: "id")
        let mutation = Mutation(
            table: table, row: DecodedRow(operation: "insert", before: nil, after: [.signed(1), .unsigned(0)]),
            eventOffset: "4", rowIndex: 0)
        let prepared = PreparedDMLGroup(group: try groups()[0], mutations: [mutation], relayEnd: 0)
        var operations: [String] = []
        let result = InnoDBExecution.run(
            [prepared], cancellation: .init(), maximumInsertRows: 32, maximumInsertBytes: 1_048_576,
            begin: { operations.append("begin") }, commit: { XCTFail("must not commit") },
            rollback: { operations.append("rollback") },
            write: { _ in
                operations.append("write")
                throw ApplyError("after-image mismatch")
            }, insert: { _ in XCTFail("unexpected chunk") },
            resetTrace: {}, trace: { .init(phase: .acknowledged) })
        XCTAssertEqual(operations, ["begin", "write", "rollback"])
        XCTAssertEqual(result.acknowledged, [0])
        XCTAssertEqual(result.diagnostic?.transactionOutcome, "rolledBack")
    }
}
