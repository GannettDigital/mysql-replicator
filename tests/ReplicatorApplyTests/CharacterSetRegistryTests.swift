import XCTest

@testable import ReplicatorApply

final class CharacterSetRegistryTests: XCTestCase {
    func testNativeIdentityAndVersionNamesStaySeparateFromColumnSupport() throws {
        XCTAssertEqual(Set(CharacterSetRegistry.collations.map(\.id)).count, CharacterSetRegistry.collations.count)
        for (id, old, new) in [
            (UInt32(33), "utf8_general_ci", "utf8mb3_general_ci"),
            (83, "utf8_bin", "utf8mb3_bin"), (192, "utf8_unicode_ci", "utf8mb3_unicode_ci"),
        ] {
            let entry = try XCTUnwrap(CharacterSetRegistry.collation(id: id))
            XCTAssertEqual(entry.characterSet, "utf8mb3")
            XCTAssertEqual(entry.name(on: .mysql57), old)
            XCTAssertEqual(entry.name(on: .mysql84), new)
            XCTAssertEqual(CharacterSetRegistry.columnCollation(named: old)?.id, id)
            XCTAssertEqual(CharacterSetRegistry.columnCollation(named: new)?.id, id)
            XCTAssertTrue(DDLQueryContextDiagnostic.collation(id).contains(old))
            XCTAssertTrue(DDLQueryContextDiagnostic.collation(id).contains(new))
        }
        let newer = try XCTUnwrap(CharacterSetRegistry.collation(id: 255))
        XCTAssertNil(newer.name(on: .mysql57))
        XCTAssertEqual(newer.name(on: .mysql84), "utf8mb4_0900_ai_ci")
        XCTAssertNil(CharacterSetRegistry.collation(id: 65535))
    }
    func testClientEncodingFallbackDoesNotTranslateComparisonCollation() throws {
        XCTAssertEqual(CharacterSetRegistry.clientEncodingID(255, target: .mysql57), 45)
        XCTAssertEqual(CharacterSetRegistry.clientEncodingID(255, target: .mysql84), 255)
        for id: UInt32 in [8, 33, 45, 46, 83, 192, 224, 65535] {
            XCTAssertEqual(CharacterSetRegistry.clientEncodingID(id, target: .mysql57), id)
            XCTAssertEqual(CharacterSetRegistry.clientEncodingID(id, target: .mysql84), id)
        }
        XCTAssertEqual(CompatibilityPolicy().targetID(255), 255)
        let policy = CompatibilityPolicy(collations: ["utf8mb4_0900_ai_ci": "utf8mb4_unicode_ci"])
        try policy.validate()
        XCTAssertEqual(policy.targetID(255), 224)
    }
    func testColumnSupportRemainsExplicit() throws {
        let ids: [UInt32] =
            [5, 8, 11, 15, 31, 33, 45, 46, 47, 48, 49, 65, 83, 94, 223] + Array(192...215) + Array(224...247)
        XCTAssertEqual(
            Set(
                CharacterSetRegistry.collations.filter {
                    $0.supportsColumns && ["utf8mb3", "utf8mb4", "latin1", "ascii"].contains($0.characterSet)
                }.map(\.id)), Set(ids))
        for id in ids {
            let entry = try XCTUnwrap(CharacterSetRegistry.collation(id: id))
            for server: CharacterSetRegistry.Server in [.mysql57, .mysql84] {
                let name = try XCTUnwrap(entry.name(on: server))
                try ApplyColumn(name: "v", type: "varchar(10)", nullable: true, collation: name).validate()
                XCTAssertEqual(CharacterSetRegistry.columnCollation(named: name)?.id, id)
            }
        }
        for name in [
            "utf8mb4_general_ci", "utf8mb4_bin", "utf8mb4_unicode_ci", "latin1_swedish_ci", "latin1_bin",
            "ascii_general_ci", "ascii_bin", "utf8_general_ci", "utf8mb3_general_ci",
        ] {
            let column = ApplyColumn(name: "v", type: "varchar(10)", nullable: true, collation: name)
            try column.validate()
        }
        for name in ["utf8mb4_0900_ai_ci", "unknown"] {
            XCTAssertThrowsError(
                try ApplyColumn(name: "v", type: "varchar(10)", nullable: true, collation: name).validate())
        }
        for name in ["latin1_swedish_ci", "utf8_general_ci", "ascii_bin", "utf8mb4_0900_ai_ci", "unknown"] {
            XCTAssertThrowsError(try CompatibilityPolicy(collations: ["utf8mb4_0900_ai_ci": name]).validate())
        }
    }
}
