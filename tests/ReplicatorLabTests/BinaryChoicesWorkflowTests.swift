import Foundation
import XCTest

@testable import ReplicatorLabCore

final class BinaryChoicesWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.binaryChoices }
    private let definition =
        "id INT PRIMARY KEY,e ENUM(0xFF,0x61,X'') CHARACTER SET binary DEFAULT X'FF',s SET(X'41',B'1100001') CHARACTER SET binary DEFAULT X'412C61',l ENUM(X'e9',0xff) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT X'e9'"
    private let originalSQL = [
        "INSERT INTO poc.matrix_binarychoices VALUES(1,DEFAULT,DEFAULT,DEFAULT),(2,2,1,2),(3,3,2,1),(4,NULL,NULL,NULL)",
        "ALTER TABLE poc.matrix_binarychoices ALTER e SET DEFAULT X'61',ALTER s SET DEFAULT X'41'; UPDATE poc.matrix_binarychoices SET e=DEFAULT,s=DEFAULT,l=1 WHERE id=2",
        "UPDATE poc.matrix_binarychoices SET e=1,s=3,l=2 WHERE id=3; DELETE FROM poc.matrix_binarychoices WHERE id=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=4 AND SUM(id=1 AND HEX(e)='FF' AND s+0=3 AND HEX(s)='412C61' AND HEX(l)='E9')=1 AND SUM(id=2 AND HEX(e)='61' AND s+0=1 AND HEX(l)='FF')=1 AND SUM(id=3 AND e+0=3 AND HEX(e)='' AND s+0=2)=1 FROM poc.matrix_binarychoices",
        "SELECT COUNT(*)=1 FROM poc.matrix_binarychoices WHERE id=2 AND e+0=2 AND HEX(e)='61' AND s+0=1 AND HEX(s)='41' AND HEX(l)='E9'",
        "SELECT COUNT(*)=3 AND SUM(id=3 AND HEX(e)='FF' AND s+0=3 AND HEX(l)='FF')=1 AND SUM(id=4 AND e IS NULL)=1 FROM poc.matrix_binarychoices",
    ]
    private let initialRows =
        "1\t1\tFF\t3\t412C61\t1\tE9\n2\t2\t61\t1\t41\t2\tFF\n3\t3\t\t2\t61\t1\tE9\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
    private let changedRows =
        "1\t1\tFF\t3\t412C61\t1\tE9\n2\t2\t61\t1\t41\t1\tE9\n3\t3\t\t2\t61\t1\tE9\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
    private let finalRows =
        "2\t2\t61\t1\t41\t1\tE9\n3\t1\tFF\t3\t412C61\t2\tFF\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
    private let projection =
        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(l+0,'NULL'),IFNULL(HEX(l),'NULL') FROM poc."

    func testOriginalBinaryDeclarationsScriptsAndMetadataInputsRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.rowMetadata, "FULL")
        XCTAssertEqual(fixture.orderBy, "id")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
            XCTAssertTrue(fixture.applies(to: profile))
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(cold.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(cold.phases[0].sql, originalSQL[0])
            XCTAssertEqual(cold.phases[0].check, originalChecks[0])
            XCTAssertEqual(cold.rowMetadata, "FULL")
        }
    }

    func testBatchesPreserveMultiGTIDScriptsAndSessionResets() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            ["matrix_binarychoices", "bc_after_insert", "bc_after_default"].map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactionCount, 3)
        XCTAssertEqual(plan.body.transactions, [1, 2, 2, 1, 1, 2])
        XCTAssertEqual(plan.body.transactionCount, 9)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 5)
        XCTAssertEqual(plan.expectedRows, 16)
        let expected =
            originalSQL.map { "USE poc; " + $0 }
            + [
                "USE poc; "
                    + originalSQL[0].replacingOccurrences(of: "poc.matrix_binarychoices", with: "poc.bc_after_insert")
            ]
            + originalSQL.prefix(2).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_binarychoices", with: "poc.bc_after_default")
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

    func testAllThreeOldPredicatesKeepTheirSQLAndExpectedValues() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (index, table) in ["bc_after_insert", "bc_after_default", "matrix_binarychoices"].enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalChecks[index].replacingOccurrences(of: "poc.matrix_binarychoices", with: "poc." + table))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testRowsKeepBinaryLatin1OrdinalsEmptyMemberAndNulls() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, table, value) in [
            ("initial-rows", "bc_after_insert", initialRows),
            ("changed-default-rows", "bc_after_default", changedRows),
            ("final-rows", "matrix_binarychoices", finalRows),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            XCTAssertEqual(check.check.sql, projection + table + " ORDER BY id")
            XCTAssertTrue(
                value.split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == 7
                })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(
                    try check.result(
                        [id: value.replacingOccurrences(of: "FF", with: "C3BF")], engine: engine, role: "target"))
                XCTAssertThrowsError(
                    try check.result(
                        [id: value.replacingOccurrences(of: "E9", with: "C3A9")], engine: engine, role: "target"))
                XCTAssertThrowsError(
                    try check.result(
                        [id: value.replacingOccurrences(of: "NULL", with: "")], engine: engine, role: "target"))
            }
        }
        let initial = try XCTUnwrap(plan.final.checks.first { $0.id == "initial-rows" })
        XCTAssertThrowsError(
            try initial.result(
                [initial.id: initialRows.replacingOccurrences(of: "3\t3\t\t2", with: "3\t0\t\t2")], engine: "MyISAM",
                role: "target"))
        let changed = try XCTUnwrap(plan.final.checks.first { $0.id == "changed-default-rows" })
        XCTAssertThrowsError(try changed.result([changed.id: initialRows], engine: "MyISAM", role: "target"))
        let final = try XCTUnwrap(plan.final.checks.first { $0.id == "final-rows" })
        XCTAssertThrowsError(try final.result([final.id: changedRows], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testDefaultQueriesCheckBytesBeforeAndAfterAlter() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, table, value) in [
            ("original-default-bytes", "bc_after_insert", "FF\t412C61\tE9"),
            ("changed-default-bytes", "bc_after_default", "61\t41\tE9"),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.expected, value)
            XCTAssertEqual(
                check.check.sql,
                "SELECT HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(l)) FROM poc." + table + " WHERE id=1")
            _ = try check.result([id: value], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([id: value + "00"], engine: "MyISAM", role: "target"))
        }
    }

    func testIndependentRawSchemaOracleKeepsLabelsAndChangedDefaults() throws {
        let raw =
            Data("t\tCREATE TABLE `t` (\n  `e` enum('".utf8) + Data([255])
            + Data("','a','') CHARACTER SET binary DEFAULT '".utf8) + Data([255])
            + Data("',\n  `s` set('A','a') CHARACTER SET binary DEFAULT 'A,a'\n)\n".utf8)
        let modern =
            "t\tCREATE TABLE `t` (\n  `e` enum(0xFF,0x61,X'') CHARACTER SET binary DEFAULT X'FF',\n  `s` set('A','a') CHARACTER SET binary DEFAULT 0x412C61\n)\n"
        let changed = modern.replacingOccurrences(of: "DEFAULT X'FF'", with: "DEFAULT X'61'").replacingOccurrences(
            of: "DEFAULT 0x412C61", with: "DEFAULT X'41'")
        let oldE = try NativeChoiceDefinition.read(raw, column: "e")
        let oldS = try NativeChoiceDefinition.read(raw, column: "s")
        XCTAssertEqual(oldE, try NativeChoiceDefinition.read(Data(modern.utf8), column: "e"))
        XCTAssertEqual(oldS, try NativeChoiceDefinition.read(Data(modern.utf8), column: "s"))
        XCTAssertEqual(oldE.type, "enum(X'ff',X'61',X'')")
        XCTAssertEqual(oldS.type, "set(X'41',X'61')")
        XCTAssertEqual(oldE.defaultValue, "X'ff'")
        XCTAssertEqual(oldS.defaultValue, "X'412c61'")
        let newE = try NativeChoiceDefinition.read(Data(changed.utf8), column: "e")
        let newS = try NativeChoiceDefinition.read(Data(changed.utf8), column: "s")
        XCTAssertEqual(newE.type, oldE.type)
        XCTAssertEqual(newS.type, oldS.type)
        XCTAssertEqual(newE.defaultValue, "X'61'")
        XCTAssertEqual(newS.defaultValue, "X'41'")
    }

    func testCleanupSharedTitleAndRemainingChoiceCases() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 8)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.bc_after_insert,poc.bc_after_default"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM and SET: binary labels and hex/bit defaults")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-binarychoices" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "binarydefaults", "textdefaults", "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings",
                "spatial", "json", "typedjson", "jsonpartial", "floatbounds", "zerofill", "fixedfloating", "floating",
                "bits", "fixed", "enumzero", "choices", "widechoices", "integers", "decimal", "temporal", "precision",
                "lob",
                "defaults",
                "floatingautofloat", "floatingautodouble", "floatingautofixedfloat", "floatingautounsigneddouble",
            ])
    }
}
