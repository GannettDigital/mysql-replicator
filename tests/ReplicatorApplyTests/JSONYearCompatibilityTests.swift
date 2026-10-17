import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

extension JSONTypeTests {
    func testYearTranslationIsExplicitAndPreservesSourceEvidence() throws {
        let policy = CompatibilityPolicy(jsonYearToInteger: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for year in ["0", "0000", "1901", "2026", "2155"] {
            let raw = Data(year.utf8).map { String(format: "%02x", $0) }.joined()
            let source = try document(13, "", raw)
            let evidence = try encoder.encode(DecodedValue.json(source))
            XCTAssertEqual(try CompatibilityPolicy().targetJSON(source), source)
            let target = try policy.targetJSON(source)
            XCTAssertEqual(target.scalarChecks.first?.type, "UNSIGNED INTEGER")
            XCTAssertTrue(try target.matchesTargetText(String(UInt16(year)!)))
            XCTAssertFalse(try target.matchesTargetText("2025"))
            XCTAssertFalse(try source.matchesTargetText(String(UInt16(year)!)))
            let bind = try XCTUnwrap(JSONSQL.scalar(target.typedValues[0].scalar)?.binds.first)
            XCTAssertTrue(bind.isUnsigned)
            XCTAssertEqual(bind.buffer?.getInteger(at: 0, endianness: .little, as: UInt64.self), UInt64(year))
            XCTAssertEqual(try policy.targetJSON(target), target)
            XCTAssertEqual(try encoder.encode(DecodedValue.json(source)), evidence)
        }
        for raw in [
            "", "ff", "2d31", "3230323620", "3230323600", "31393030", "32313536", "39393939", "3939", "3030303030",
        ] {
            XCTAssertThrowsError(try policy.targetJSON(document(13, "", raw)))
        }
        let binary = try document(253, "", "01020304")
        XCTAssertEqual(try policy.targetJSON(binary), binary)
        let ordinary = try JSONDocument(text: #"{"year":2026,"s":"base64:type13:MjAyNg=="}"#)
        XCTAssertEqual(try policy.targetJSON(ordinary), ordinary)
    }
    func testYearTranslationHandlesNestedAndEscapedPaths() throws {
        let source: [String: Any] = [
            "text": #"{"a\"b":[null,{"y":null}],"plain":2026}"#,
            "typed": [
                ["path": #"$."a\"b"[0]"#, "type": 13, "value": "", "rawHex": "31393031", "precision": 0, "scale": 0],
                ["path": #"$."a\"b"[1].y"#, "type": 13, "value": "", "rawHex": "32313535", "precision": 0, "scale": 0],
            ],
        ]
        let document = try JSONDocument(source: JSONSerialization.data(withJSONObject: source))
        let target = try CompatibilityPolicy(jsonYearToInteger: true).targetJSON(document)
        XCTAssertTrue(try target.matchesTargetText(#"{"plain":2026,"a\"b":[1901,{"y":2155}]}"#))
        XCTAssertEqual(target.typedValues.map(\.scalar.type), [1001, 1001])
        XCTAssertEqual(document.typedValues.map(\.scalar.type), [13, 13])
        XCTAssertEqual(target.scalarChecks.map(\.type), ["UNSIGNED INTEGER", "UNSIGNED INTEGER", "INTEGER"])
    }
    func testOldPoliciesRemainStrictAndNewPolicyRoundTrips() throws {
        let old = try JSONDecoder().decode(CompatibilityPolicy.self, from: Data(#"{"collations":{}}"#.utf8))
        XCTAssertEqual(old, CompatibilityPolicy())
        let policy = CompatibilityPolicy(jsonYearToInteger: true)
        XCTAssertEqual(try JSONDecoder().decode(CompatibilityPolicy.self, from: JSONEncoder().encode(policy)), policy)
    }
}

extension ResumeTests {
    func testYearPolicyProfileValidationAndDurablePinning() throws {
        let path = try directory()
        for profile in ReplicationProfile.allCases {
            let c = try helper.config(path.path, profile: profile.rawValue, jsonYearToInteger: true)
            if profile == .mysql57To84InnoDB {
                XCTAssertNoThrow(try c.validate())
            } else {
                XCTAssertThrowsError(try c.validate())
            }
        }
        let enabled = try helper.config(
            path.path, profile: ReplicationProfile.mysql57To84InnoDB.rawValue, jsonYearToInteger: true)
        let strict = try helper.config(path.path, profile: ReplicationProfile.mysql57To84InnoDB.rawValue)
        try seed(enabled)
        do { _ = try StateStore(configuration: enabled, initialize: false) }
        XCTAssertThrowsError(try StateStore(configuration: strict, initialize: false))
        XCTAssertNoThrow(try Recovery.inspect(configuration: enabled))
        XCTAssertThrowsError(try Recovery.inspect(configuration: strict))
        XCTAssertTrue(try Recovery.inspect(configuration: enabled).compatibility.jsonYearToInteger)
        let other = try directory()
        try seed(helper.config(other.path, profile: ReplicationProfile.mysql57To84InnoDB.rawValue))
        XCTAssertThrowsError(
            try StateStore(
                configuration: helper.config(
                    other.path, profile: ReplicationProfile.mysql57To84InnoDB.rawValue, jsonYearToInteger: true),
                initialize: false))
    }
}
