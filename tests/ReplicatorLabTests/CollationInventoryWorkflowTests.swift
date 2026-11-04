import Foundation
import XCTest

@testable import ReplicatorLabCore

final class CollationInventoryWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.characterCollations }
    // Fixed native ID/name expectations. Do not read the apply registry here.
    private let inventory = """
        5 latin1 latin1_german1_ci
        8 latin1 latin1_swedish_ci
        11 ascii ascii_general_ci
        15 latin1 latin1_danish_ci
        31 latin1 latin1_german2_ci
        33 utf8 utf8_general_ci
        45 utf8mb4 utf8mb4_general_ci
        46 utf8mb4 utf8mb4_bin
        47 latin1 latin1_bin
        48 latin1 latin1_general_ci
        49 latin1 latin1_general_cs
        65 ascii ascii_bin
        83 utf8 utf8_bin
        94 latin1 latin1_spanish_ci
        192 utf8 utf8_unicode_ci
        193 utf8 utf8_icelandic_ci
        194 utf8 utf8_latvian_ci
        195 utf8 utf8_romanian_ci
        196 utf8 utf8_slovenian_ci
        197 utf8 utf8_polish_ci
        198 utf8 utf8_estonian_ci
        199 utf8 utf8_spanish_ci
        200 utf8 utf8_swedish_ci
        201 utf8 utf8_turkish_ci
        202 utf8 utf8_czech_ci
        203 utf8 utf8_danish_ci
        204 utf8 utf8_lithuanian_ci
        205 utf8 utf8_slovak_ci
        206 utf8 utf8_spanish2_ci
        207 utf8 utf8_roman_ci
        208 utf8 utf8_persian_ci
        209 utf8 utf8_esperanto_ci
        210 utf8 utf8_hungarian_ci
        211 utf8 utf8_sinhala_ci
        212 utf8 utf8_german2_ci
        213 utf8 utf8_croatian_ci
        214 utf8 utf8_unicode_520_ci
        215 utf8 utf8_vietnamese_ci
        223 utf8 utf8_general_mysql500_ci
        224 utf8mb4 utf8mb4_unicode_ci
        225 utf8mb4 utf8mb4_icelandic_ci
        226 utf8mb4 utf8mb4_latvian_ci
        227 utf8mb4 utf8mb4_romanian_ci
        228 utf8mb4 utf8mb4_slovenian_ci
        229 utf8mb4 utf8mb4_polish_ci
        230 utf8mb4 utf8mb4_estonian_ci
        231 utf8mb4 utf8mb4_spanish_ci
        232 utf8mb4 utf8mb4_swedish_ci
        233 utf8mb4 utf8mb4_turkish_ci
        234 utf8mb4 utf8mb4_czech_ci
        235 utf8mb4 utf8mb4_danish_ci
        236 utf8mb4 utf8mb4_lithuanian_ci
        237 utf8mb4 utf8mb4_slovak_ci
        238 utf8mb4 utf8mb4_spanish2_ci
        239 utf8mb4 utf8mb4_roman_ci
        240 utf8mb4 utf8mb4_persian_ci
        241 utf8mb4 utf8mb4_esperanto_ci
        242 utf8mb4 utf8mb4_hungarian_ci
        243 utf8mb4 utf8mb4_sinhala_ci
        244 utf8mb4 utf8mb4_german2_ci
        245 utf8mb4 utf8mb4_croatian_ci
        246 utf8mb4 utf8mb4_unicode_520_ci
        247 utf8mb4 utf8mb4_vietnamese_ci
        """
    private var members: [(Int, String, String)] {
        inventory.split(separator: "\n").map {
            let fields = $0.split(separator: " ")
            return (Int(fields[0])!, String(fields[1]), String(fields[2]))
        }
    }
    private func bytes(_ charset: String) -> String {
        ["ascii": "410020", "latin1": "E900FF20", "utf8": "C3A9E4B8AD0020", "utf8mb4": "C3A9E4B8AD0020"][charset]!
    }
    private var originalDefinition: String {
        "id VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci PRIMARY KEY,"
            + members.map { id, charset, collation in
                "c\(id) VARCHAR(12) CHARACTER SET \(charset) COLLATE \(collation) DEFAULT 'A'"
            }.joined(separator: ",")
    }
    private var originalSQL: [String] {
        [
            "INSERT INTO poc.matrix_collations(id) VALUES('first'),('second')",
            "UPDATE poc.matrix_collations SET id='FirstX',"
                + members.map { "c\($0.0)=CONVERT(0x\(bytes($0.1)) USING \($0.1))" }.joined(separator: ",")
                + " WHERE id='FIRST'",
            "ALTER TABLE poc.matrix_collations MODIFY c49 VARCHAR(12) CHARACTER SET latin1 COLLATE latin1_spanish_ci DEFAULT 'A'; UPDATE poc.matrix_collations SET c49=NULL WHERE id='second'",
            "DELETE FROM poc.matrix_collations WHERE id='FIRSTX'",
        ]
    }
    private var originalChecks: [String] {
        [
            "SELECT COUNT(*)=2 AND SUM(c5='A')=2 AND SUM(c247='A')=2 FROM poc.matrix_collations",
            "SELECT COUNT(*)=1 FROM poc.matrix_collations WHERE id='firstx' AND "
                + members.map { "HEX(c\($0.0))='\(bytes($0.1))'" }.joined(separator: " AND "),
            "SELECT COUNT(*)=1 FROM poc.matrix_collations WHERE id='second' AND c49 IS NULL",
            "SELECT COUNT(*)=1 AND MIN(id)='second' AND SUM(c49 IS NULL)=1 FROM poc.matrix_collations",
        ]
    }

    func testOriginalInventoryScriptsAndMetadataInputsRemain() throws {
        XCTAssertEqual(members.count, 63)
        XCTAssertEqual(Set(members.map { $0.0 }).count, 63)
        for (charset, count) in [("ascii", 2), ("latin1", 8), ("utf8", 27), ("utf8mb4", 26)] {
            XCTAssertEqual(members.filter { $0.1 == charset }.count, count)
        }
        XCTAssertEqual(Data(fixture.definition.utf8), Data(originalDefinition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map { Data($0.check.utf8) }, originalChecks.map { Data($0.utf8) })
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertNil(fixture.replicatedReplacement)
        XCTAssertNotNil(DMLCompatibilityCases.nativeEncodings.workflow)
        for profile in LabProfile.allCases {
            let metadata = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(metadata.definition.utf8), Data(originalDefinition.utf8))
            XCTAssertEqual(metadata.phases[0].sql, originalSQL[0])
            XCTAssertEqual(metadata.phases[0].check, originalChecks[0])
        }
    }

    func testBatchesKeepExactScriptsSessionsAndDifferentGTIDCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["matrix_collations", "cl_after_insert", "cl_after_update", "cl_after_modify"]
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            tables.map {
                "CREATE TABLE poc." + $0 + "(" + originalDefinition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.transactions, [1, 1, 2, 1, 1, 1, 1, 1, 1, 2])
        XCTAssertEqual(plan.body.transactionCount, 12)
        XCTAssertEqual(plan.expectedDDL, 6)
        XCTAssertEqual(plan.expectedRows, 14)
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (length, table) in [(1, "cl_after_insert"), (2, "cl_after_update"), (3, "cl_after_modify")] {
            expected += originalSQL.prefix(length).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_collations", with: "poc." + table)
            }
        }
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        for batch in [plan.prepare, plan.body, plan.cleanup] {
            let queries = try LabSQLPhase.queries(
                batch.writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
            for (index, write) in batch.writes.enumerated() {
                XCTAssertTrue(queries[index * 4].sql.hasPrefix(LabProfile.forward.session))
                XCTAssertTrue(queries[index * 4].sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                XCTAssertFalse(write.sql.contains("BEGIN"))
                XCTAssertFalse(write.sql.contains("COMMIT"))
            }
        }
    }

    func testOriginalPredicatesAndCaseInsensitiveKeyMatchingRemain() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["cl_after_insert", "cl_after_update", "cl_after_modify", "matrix_collations"]
        for (index, sql) in originalChecks.enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql, sql.replacingOccurrences(of: "poc.matrix_collations", with: "poc." + tables[index]))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
        XCTAssertTrue(plan.body.writes[1].sql.contains("id='FirstX'"))
        XCTAssertTrue(plan.body.writes[1].sql.hasSuffix("WHERE id='FIRST'"))
        XCTAssertTrue(plan.final.checks[1].check.sql.contains("id='firstx'"))
        XCTAssertTrue(plan.body.writes[3].sql.hasSuffix("WHERE id='FIRSTX'"))
    }

    func testFullRowsCheckEveryMemberDefaultsBytesNullAndStoredKeyCase() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        func expected(_ key: String, updated: Bool = false, null: Bool = false) -> String {
            ([key]
                + members.map { id, charset, _ in
                    null && id == 49 ? "NULL" : updated ? bytes(charset) : "41"
                }).joined(separator: "\t")
        }
        let expectedValues = [
            "initial-rows": expected("6669727374") + "\n" + expected("7365636F6E64"),
            "updated-rows": expected("466972737458", updated: true) + "\n" + expected("7365636F6E64"),
            "modified-rows": expected("466972737458", updated: true) + "\n" + expected("7365636F6E64", null: true),
            "surviving-row": expected("7365636F6E64", null: true),
        ]
        let fields = ["HEX(id)"] + members.map { "IFNULL(HEX(c\($0.0)),'NULL')" }
        let tables = [
            "initial-rows": "cl_after_insert", "updated-rows": "cl_after_update", "modified-rows": "cl_after_modify",
            "surviving-row": "matrix_collations",
        ]
        for (id, value) in expectedValues {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.expected, value)
            XCTAssertEqual(
                check.check.sql,
                "SELECT " + fields.joined(separator: ",") + " FROM poc." + tables[id]! + " ORDER BY BINARY id")
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                var changed = value.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
                XCTAssertTrue(changed.allSatisfy { $0.count == 64 })
                for number in [5, 11, 49, 192, 247] {
                    let index = try XCTUnwrap(members.firstIndex { $0.0 == number }) + 1
                    var row = changed[0]
                    row[index] = "BADHEX"
                    changed[0] = row
                    XCTAssertThrowsError(
                        try check.result(
                            [id: changed.map { $0.joined(separator: "\t") }.joined(separator: "\n")], engine: engine,
                            role: "target"))
                    changed = value.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
                }
            }
        }
    }

    func testMetadataKeepsAllColumnsAndChangesOnlyC49Mapping() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, modified, table) in [
            ("original-collation-ids", false, "cl_after_update"), ("modified-collation-ids", true, "cl_after_modify"),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            let expected =
                ["id\t246\tutf8mb4\tutf8mb4_unicode_520_ci"]
                + members.map { number, charset, name in
                    "c\(number)\t\(modified && number == 49 ? 94 : number)\t\(charset)\t\(modified && number == 49 ? "latin1_spanish_ci" : name)"
                }
            XCTAssertEqual(check.check.expected, expected.joined(separator: "\n"))
            XCTAssertTrue(
                check.check.sql.contains("JOIN information_schema.COLLATIONS k ON k.COLLATION_NAME=c.COLLATION_NAME"))
            XCTAssertTrue(check.check.sql.contains("REPLACE(c.CHARACTER_SET_NAME,'utf8mb3','utf8')"))
            XCTAssertTrue(check.check.sql.contains("REPLACE(c.COLLATION_NAME,'utf8mb3_','utf8_')"))
            XCTAssertTrue(check.check.sql.hasSuffix("c.TABLE_NAME='\(table)' ORDER BY c.ORDINAL_POSITION"))
            let membersOnly = expected.dropFirst().map { $0.split(separator: "\t") }
            XCTAssertEqual(membersOnly.count, 63)
            XCTAssertEqual(Set(membersOnly.map { $0[1] }).count, modified ? 62 : 63)
            XCTAssertEqual(membersOnly.filter { $0[1] == "94" }.count, modified ? 2 : 1)
            _ = try check.result([id: expected.joined(separator: "\n")], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(
                try check.result([id: expected.dropLast().joined(separator: "\n")], engine: "MyISAM", role: "target"))
            if modified {
                XCTAssertThrowsError(
                    try check.result(
                        [
                            id: expected.joined(separator: "\n").replacingOccurrences(
                                of: "c49\t94\tlatin1\tlatin1_spanish_ci", with: "c49\t49\tlatin1\tlatin1_general_cs")
                        ], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testCleanupOwnershipAndSharedTitle() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 10)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.cl_after_insert,poc.cl_after_update,poc.cl_after_modify"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(
            fixture.displayName, "Character sets and collations: collation IDs, stored bytes and case-insensitive keys")
        XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-collations" }?.test.name, fixture.displayName)
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertNotNil(DMLCompatibilityCases.nativeEncodings.workflow)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "identifiercase",
                "unicodeidentifiers", "enumzero", "choices",
                "widechoices",
            ])
    }
}
