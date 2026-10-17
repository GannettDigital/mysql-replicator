import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class PartitionCompatibilityTests: XCTestCase {
    func statement(_ sql: String, profile: ReplicationProfile = .mysql57To84InnoDB) throws -> DDLStatement {
        try DDLStatement.parse(
            QueryControl(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()), profile: profile)
    }
    func table(_ suffix: String) throws -> ApplyTable {
        guard case .create(let table, _) = try statement("CREATE TABLE t(id INT PRIMARY KEY) " + suffix) else {
            throw ApplyError("expected CREATE")
        }
        try table.validate()
        return table
    }
    func testGeneratedNamesAndSavedSchemaCompatibility() throws {
        let schema = try table(
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
        )
        XCTAssertEqual(
            schema.partitions.flatMap { $0.subpartitions!.map(\.name) }, ["p0sp0", "p0sp1", "p1sp0", "p1sp1"])
        XCTAssertEqual(schema.partitions[0].subpartitions?.first?.expression, "`id`")
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(schema)), schema)
        let legacy = Data(#"{"name":"p0","method":"HASH","expression":"`id`","description":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ApplyPartition.self, from: legacy).subpartitions)
        XCTAssertEqual(try table("PARTITION BY KEY() PARTITIONS 2").partitions[0].expression, "")
    }
    func testExplicitNamesAndLifecycle() throws {
        var schema = try table(
            "PARTITION BY RANGE(id) SUBPARTITION BY KEY(id) (PARTITION p0 VALUES LESS THAN(10)(SUBPARTITION s0, SUBPARTITION s1),PARTITION p1 VALUES LESS THAN MAXVALUE(SUBPARTITION s2,SUBPARTITION s3))"
        )
        guard
            case .alter(_, let actions) = try statement(
                "ALTER TABLE t REORGANIZE PARTITION p1 INTO (PARTITION p2 VALUES LESS THAN(20),PARTITION p3 VALUES LESS THAN MAXVALUE)"
            ), case .partition(let change) = actions[0]
        else { return XCTFail() }
        schema = try change.applying(to: schema)
        XCTAssertEqual(
            schema.partitions.flatMap { $0.subpartitions!.map(\.name) },
            ["s0", "s1", "p2sp0", "p2sp1", "p3sp0", "p3sp1"])
        XCTAssertEqual(try PartitionChange.truncate(["s0"]).applying(to: schema), schema)
        XCTAssertEqual(
            try PartitionChange.exchange("s1", .init(database: "poc", table: "stage")).applying(to: schema), schema)
        XCTAssertThrowsError(
            try PartitionChange.exchange("p0", .init(database: "poc", table: "stage")).applying(to: schema))
        XCTAssertThrowsError(try PartitionChange.drop(["s0"]).applying(to: schema))
        XCTAssertThrowsError(try PartitionChange.truncate(["absent"]).applying(to: schema))
        XCTAssertEqual(try PartitionChange.drop(["p0"]).applying(to: schema).partitions.count, 2)
    }
    func testNativeImplicitKeyMetadata() throws {
        for method in ["KEY", "LINEAR KEY"] {
            XCTAssertEqual(try partitionMetadataExpression(nil, method: method), "")
            XCTAssertEqual(try partitionMetadataExpression("", method: method), "")
            XCTAssertEqual(try partitionMetadataExpression("id", method: method), "`id`")
        }
        for method in ["HASH", "RANGE", "LIST"] {
            XCTAssertThrowsError(try partitionMetadataExpression(nil, method: method))
            XCTAssertThrowsError(try partitionMetadataExpression("", method: method))
        }
        let schema = try table(
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id)(PARTITION p VALUES LESS THAN MAXVALUE COMMENT='first' COMMENT='last'(SUBPARTITION 'child' ENGINE='InnoDB'))"
        )
        XCTAssertEqual(schema.partitions[0].subpartitions?.first?.name, "child")
    }
    func testHashAdditionAndEnginePolicy() throws {
        let schema = try table("PARTITION BY HASH(id) (PARTITION a ENGINE=InnoDB,PARTITION b)")
        XCTAssertEqual(
            try PartitionChange.addHash(2).applying(to: schema).partitions.map(\.name), ["a", "b", "p2", "p3"])
        XCTAssertThrowsError(try PartitionChange.addHash(8192).applying(to: schema))
        XCTAssertThrowsError(try table("PARTITION BY HASH(id) (PARTITION a ENGINE=MyISAM)"))
        XCTAssertNoThrow(
            try statement(
                "CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY HASH(id) (PARTITION a ENGINE=MyISAM)",
                profile: .mysql57To57MyISAM))
    }
    func testInconsistentDefinitionsAndLimits() throws {
        for suffix in [
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10)(SUBPARTITION a),PARTITION p1 VALUES LESS THAN MAXVALUE(SUBPARTITION b))",
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) (PARTITION p0 VALUES LESS THAN(10)(SUBPARTITION a),PARTITION p1 VALUES LESS THAN MAXVALUE)",
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 8192 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) (PARTITION p0 VALUES LESS THAN(10)(SUBPARTITION a),PARTITION p1 VALUES LESS THAN MAXVALUE(SUBPARTITION a))",
            "PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) (PARTITION p0 VALUES LESS THAN(10)(SUBPARTITION p0))",
            "PARTITION BY HASH(id) (PARTITION p0 VALUES IN(1))",
            "PARTITION BY RANGE(id) (PARTITION p0 VALUES IN(1))",
        ] { XCTAssertThrowsError(try table(suffix), suffix) }
    }
}
