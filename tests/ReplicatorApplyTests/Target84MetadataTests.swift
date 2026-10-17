import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class Target84MetadataTests: XCTestCase {
    func parse(_ sql: String, _ profile: ReplicationProfile = .mysql57To84InnoDB) throws -> DDLStatement {
        try DDLStatement.parse(
            .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data()), profile: profile)
    }
    func testMetadataSurvivesChangesAndSavedState() throws {
        guard
            case .create(let table, _) = try parse(
                "CREATE TABLE t(id INT PRIMARY KEY,p POINT NOT NULL SRID 4326,KEY k(id) INVISIBLE,SPATIAL KEY sp(p))")
        else { return XCTFail() }
        try table.validate()
        XCTAssertEqual(table.columns[1].spatialReferenceID, 4326)
        XCTAssertEqual(table.secondaryIndexes.first { $0.name == "k" }?.visible, false)
        let renamed = try IndexChange.rename("k", "renamed").applying(to: table)
        XCTAssertEqual(renamed.secondaryIndexes.first { $0.name == "renamed" }?.visible, false)
        let visible = try IndexChange.visibility("renamed", true).applying(to: renamed)
        XCTAssertNil(visible.secondaryIndexes.first { $0.name == "renamed" }?.visible)
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self, from: JSONEncoder().encode(renamed)), renamed)
        XCTAssertNoThrow(try ReplicationProfile.mysql57To84InnoDB.targetContract.validateSchemaFeatures(table))
        XCTAssertThrowsError(try ReplicationProfile.mysql57To57InnoDB.targetContract.validateSchemaFeatures(table))
        XCTAssertNoThrow(try parse("ALTER TABLE t ALTER INDEX k INVISIBLE"))
        XCTAssertNoThrow(try parse("CREATE INDEX k ON t(id) INVISIBLE"))
    }
    func testNativeLimitsAndLegacyMetadata() throws {
        for sql in [
            "CREATE TABLE t(id INT PRIMARY KEY,p INT SRID 0)",
            "CREATE TABLE t(id INT PRIMARY KEY,p POINT SRID 4294967296)",
            "CREATE TABLE t(id INT,PRIMARY KEY(id) INVISIBLE)",
        ] { XCTAssertThrowsError(try parse(sql), sql) }
        for sql in [
            "CREATE TABLE t(id INT PRIMARY KEY,p POINT SRID 0)",
            "CREATE TABLE t(id INT PRIMARY KEY,KEY k(id) INVISIBLE)", "ALTER TABLE t ALTER INDEX k VISIBLE",
        ] { XCTAssertThrowsError(try parse(sql, .mysql57To57InnoDB), sql) }
        let legacy = try JSONDecoder().decode(
            ApplyIndex.self,
            from: Data(#"{"name":"k","unique":false,"parts":[{"column":"id","direction":"A"}],"type":"BTREE"}"#.utf8))
        var explicit = legacy
        explicit.visible = true
        XCTAssertEqual(legacy, explicit)
        explicit.visible = false
        XCTAssertNotEqual(legacy, explicit)
    }
}
