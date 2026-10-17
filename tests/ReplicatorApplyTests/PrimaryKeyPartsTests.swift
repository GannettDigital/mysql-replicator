import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class PrimaryKeyPartsTests: XCTestCase {
    func table(_ sql: String, profile: ReplicationProfile = .mysql57To84InnoDB) throws -> ApplyTable {
        guard
            case .create(let table, _) = try DDLStatement.parse(
                .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()), profile: profile)
        else { throw ApplyError("missing table") }
        var columns = table.columns
        for i in columns.indices where (try? DMLColumnType(columns[i].type).isText) == true {
            columns[i].collation = "utf8mb4_bin"
            columns[i].characterSet = "utf8mb4"
        }
        return table.replacing(columns: columns)
    }
    func testPrefixAndDirectionSurviveSavedSchemasAndRename() throws {
        let value = try table("CREATE TABLE t(k VARCHAR(40),b BLOB,n INT,PRIMARY KEY(k(8) DESC,b(4)))")
        try value.validate()
        XCTAssertEqual(value.effectivePrimaryKeyParts.map(\.prefix), [8, 4])
        XCTAssertEqual(value.effectivePrimaryKeyParts.map(\.direction), ["D", "A"])
        XCTAssertEqual(value.rowIdentity?.columns, ["k", "b"])
        let decoded = try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        try decoded.validate()
        XCTAssertEqual(
            decoded.renamed(to: .init(database: "other", table: "u")).effectivePrimaryKeyParts,
            value.effectivePrimaryKeyParts)
        XCTAssertEqual(decoded.replacing(indexes: []).effectivePrimaryKeyParts, value.effectivePrimaryKeyParts)
        XCTAssertTrue(decoded.replacing(primaryKey: []).effectivePrimaryKeyParts.isEmpty)
        XCTAssertFalse(value.primaryKeyCovers(["k"]))
        XCTAssertFalse(value.hasForeignKeyParentIndex(["k"], rule: .innodb))
    }
    func testNativeDirectionMetadata() {
        XCTAssertEqual(NativeReplicationRules(profile: .mysql57To57InnoDB).indexDirection(nil, type: "BTREE"), "A")
        XCTAssertNil(NativeReplicationRules(profile: .mysql57To84InnoDB).indexDirection(nil, type: "BTREE"))
        XCTAssertNil(NativeReplicationRules(profile: .mysql57To57InnoDB).indexDirection(nil, type: "FULLTEXT"))
    }
    func testLegacySchemaAndNative57Direction() throws {
        let value = try table("CREATE TABLE t(id INT PRIMARY KEY)")
        let encoded = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("primaryKeyParts"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: encoded), value)
        let legacy = try table("CREATE TABLE t(k VARBINARY(30),PRIMARY KEY(k(8) DESC))", profile: .mysql57To57InnoDB)
        XCTAssertEqual(legacy.effectivePrimaryKeyParts[0].direction, "A")
        try legacy.validate()
    }
    func testInvalidPartsAndFullKeyLookup() throws {
        for sql in [
            "CREATE TABLE t(k INT,PRIMARY KEY(k(2)))", "CREATE TABLE t(k BLOB,PRIMARY KEY(k))",
            "CREATE TABLE t(k VARBINARY(4),PRIMARY KEY(k(8)))",
        ] {
            XCTAssertThrowsError(try table(sql).validate(), sql)
        }
        var value = try table("CREATE TABLE t(k VARBINARY(30),PRIMARY KEY(k(8)))")
        let plan = try DMLSQLPlan(value)
        XCTAssertTrue(plan.select.hasSuffix("WHERE `k`=?"))
        XCTAssertEqual(plan.keyIndexes, [0])
        value.primaryKeyParts = [.init(column: "absent", prefix: 8)]
        XCTAssertThrowsError(try value.validate())
    }
    func testAlterParsesPrefixAndDescendingParts() throws {
        for sql in [
            "ALTER TABLE t ADD PRIMARY KEY(k(8) DESC)", "ALTER TABLE t ADD (k VARBINARY(30),PRIMARY KEY(k(8) DESC))",
        ] {
            guard
                case .alter(_, let actions) = try DDLStatement.parse(
                    .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()),
                    profile: .mysql57To84InnoDB), case .primaryKeyParts(let parts) = actions.last
            else { return XCTFail("missing parts") }
            XCTAssertEqual(parts, [.init(column: "k", prefix: 8, direction: "D")])
        }
    }
}
