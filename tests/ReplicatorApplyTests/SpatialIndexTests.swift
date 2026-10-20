import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class SpatialIndexTests: XCTestCase {
    func table(_ sql: String) throws -> ApplyTable {
        let query = QueryControl(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())
        guard case .create(let table, _) = try DDLStatement.parse(query) else { throw ApplyError("not CREATE") }
        try table.validate()
        return table
    }
    func testGeometryBytePrefixesRemainSeparateFromSpatialIndexes() throws {
        for type in DMLColumnType.spatialTypes {
            let value = try table("CREATE TABLE t(id INT PRIMARY KEY,g \(type),KEY by_g(g(32),id))")
            XCTAssertEqual(value.secondaryIndexes[0].type, "BTREE")
            XCTAssertEqual(value.secondaryIndexes[0].parts[0].prefix, 32)
            for profile in ReplicationProfile.allCases {
                if profile.targetContract.versionPrefix == "5.7." {
                    XCTAssertNoThrow(try profile.targetContract.validateSchemaFeatures(value))
                } else {
                    XCTAssertThrowsError(try profile.targetContract.validateSchemaFeatures(value)) {
                        XCTAssertTrue(String(describing: $0).contains("geometry BTREE prefix indexes"))
                    }
                }
            }
            XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(value)), value)
        }
    }
    func testNativeIndexConstraintsStillApply() throws {
        for definition in [
            "g GEOMETRY,KEY k(g)", "g GEOMETRY,KEY k(g(0))", "g GEOMETRY,SPATIAL KEY k(g)",
            "g GEOMETRY NOT NULL,SPATIAL KEY k(g(32))", "g VARCHAR(2) COLLATE utf8mb4_bin,KEY k(g(3))",
        ] {
            XCTAssertThrowsError(try table("CREATE TABLE t(id INT PRIMARY KEY," + definition + ")"), definition)
        }
        XCTAssertNoThrow(try table("CREATE TABLE t(id INT PRIMARY KEY,g GEOMETRY NOT NULL,SPATIAL KEY k(g))"))
        XCTAssertNoThrow(try table("CREATE TABLE t(id INT PRIMARY KEY,g GEOMETRY,UNIQUE KEY k(g(32)))"))
    }
}
