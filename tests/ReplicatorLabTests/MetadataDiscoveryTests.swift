import XCTest

@testable import ReplicatorLabCore

final class MetadataDiscoveryTests: XCTestCase {
    func testRetiredCasesKeepMetadataAssertionsAndDMLOwnersInEveryScope() throws {
        let catalog = LabScenario.correctness
        XCTAssertFalse(catalog.contains { $0.id.hasPrefix("bootstrap-matrix-") })
        for fixture in DMLCompatibilityCases.cases {
            let owner = try XCTUnwrap(catalog.first { $0.id == MetadataDiscoveryCases.owner(fixture.id) })
            let dml = try XCTUnwrap(
                catalog.first { $0.id == (fixture.replicatedReplacement ?? "matrix-" + fixture.id) })
            for profile in LabProfile.allCases where fixture.applies(to: profile) {
                for variant in LabVariant.allCases
                where variant.reason(profile) == nil && variant != .withoutSourceGTIDs {
                    XCTAssertNil(owner.reason(profile, variant: variant), fixture.id)
                    XCTAssertNil(dml.reason(profile, variant: variant), fixture.id)
                    XCTAssertTrue(
                        (owner.fields(profile)["replaces"] as? [String] ?? []).contains(
                            "bootstrap-matrix-" + fixture.id))
                    XCTAssertTrue(
                        (owner.fields(profile)["assertions"] as? [String] ?? []).contains(
                            "metadata-" + MetadataDiscoveryCases.representative(fixture.id)))
                }
            }
            XCTAssertThrowsError(
                try LabScenario.select(tier: "full", family: nil, ids: ["bootstrap-matrix-" + fixture.id])
            ) {
                XCTAssertTrue(String(describing: $0).contains(owner.id))
            }
        }
    }

    func testMetadataGroupSharesFixtureAndRetainsTargetOnlyWorkflows() throws {
        let selected = try LabScenario.select(tier: "full", family: "metadata", ids: [])
        XCTAssertEqual(
            Set(selected.map(\.id)),
            Set(
                MetadataDiscoveryCases.tests.map(\.id) + [
                    "json-target84-schema", "target84-index-spatial-metadata", "expression-target84-dependencies",
                    "alter-rename-target84-refusal",
                ]))
        XCTAssertFalse(LabScenario.needsMainApplier(selected: Set(selected.map(\.id)), slice: "all"))
        for profile in LabProfile.allCases {
            let fixtures = [MetadataDiscoveryCases.columns, MetadataDiscoveryCases.encodings].flatMap {
                MetadataDiscoveryCases.fixtures($0.id, profile: profile)
            }
            XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count)
            XCTAssertFalse(fixtures.isEmpty)
            // The cold-read inputs must not silently acquire another DML phase.
            for fixture in fixtures {
                XCTAssertFalse(fixture.phases[0].expectsJSONDiff)
                XCTAssertFalse(fixture.phases[0].sql.contains("ALTER TABLE"))
                XCTAssertTrue(fixture.phases[0].sql.contains("INSERT INTO"))
            }
            XCTAssertEqual(
                fixtures.contains { $0.id == "legacybinaryset" }, profile == .mysql57InnoDB || profile == .mysql57MyISAM
            )
        }
    }

    func testLiveSchemaReadsRequireCompleteRecordsAndQueryCounts() throws {
        let record: [String: Any] = [
            "kind": "log", "message": "Target schema query totals",
            "fields": ["database": "poc", "table": "cached", "queries": "7"],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: record)
        XCTAssertTrue(try MetadataDiscoveryCases.schemaReadRecords(bytes).isEmpty)
        let stream = Data("{\"kind\":\"apply_summary\"}\n".utf8) + bytes + Data([10]) + bytes.prefix(12)
        XCTAssertEqual(try MetadataDiscoveryCases.schemaReadRecords(stream).count, 1)
        var invalid = record
        invalid["fields"] = ["database": "poc", "queries": "0"]
        XCTAssertThrowsError(
            try MetadataDiscoveryCases.schemaReadRecords(JSONSerialization.data(withJSONObject: invalid) + Data([10])))
    }
}
