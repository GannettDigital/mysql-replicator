import Foundation
import XCTest

@testable import ReplicatorLabCore

final class ExactChoicesWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.exactChoices }
    private let definition =
        "id ENUM('😀','?','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY,e ENUM('é','ÿ') CHARACTER SET latin1 COLLATE latin1_bin DEFAULT 'é',s SET('😀','?','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'a,😀',w ENUM('†','中') CHARACTER SET utf16 COLLATE utf16_bin DEFAULT '中',n ENUM('2','a') DEFAULT 2,q ENUM('2','a') DEFAULT '2',v INT"
    private let originalSQL = [
        "INSERT INTO poc.matrix_exactchoices VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,10),(2,2,2,1,1,2,20),(3,NULL,NULL,NULL,NULL,NULL,30)",
        "UPDATE poc.matrix_exactchoices SET e=1,s=7,w=2,n=2,q=1,v=21 WHERE id+0=2",
        "ALTER TABLE poc.matrix_exactchoices ALTER n SET DEFAULT '2',ALTER q SET DEFAULT 2,ADD extra SET('é','ÿ') CHARACTER SET latin1 COLLATE latin1_bin DEFAULT 'ÿ,é'; UPDATE poc.matrix_exactchoices SET n=DEFAULT,q=DEFAULT,extra=DEFAULT WHERE id+0=1",
        "DELETE FROM poc.matrix_exactchoices WHERE id+0=3; UPDATE poc.matrix_exactchoices SET id=3 WHERE id+0=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=1 AND HEX(id)='F09F9880' AND HEX(e)='E9' AND s+0=5 AND HEX(s)='F09F98802C61' AND HEX(w)='4E2D' AND n+0=2 AND q+0=1",
        "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=2 AND HEX(id)='3F' AND HEX(e)='E9' AND s+0=7 AND HEX(w)='4E2D' AND n+0=2 AND q+0=1 AND v=21",
        "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=1 AND n+0=1 AND q+0=2 AND extra+0=3 AND HEX(extra)='E92CFF'",
        "SELECT COUNT(*)=2 AND SUM(id+0=1)=0 AND SUM(id+0=3 AND HEX(id)='61' AND v=10)=1 FROM poc.matrix_exactchoices",
    ]
    private let initialRows =
        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t2\t61\t1\t32\t10\n2\t3F\t2\tFF\t2\t3F\t1\t2020\t1\t32\t2\t61\t20\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30"
    private let updatedRows =
        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t2\t61\t1\t32\t10\n2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30"
    private let changedRows =
        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t1\t32\t2\t61\t10\t3\tE92CFF\n2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\t3\tE92CFF\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30\t3\tE92CFF"
    private let finalRows =
        "2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\t3\tE92CFF\n3\t61\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t1\t32\t2\t61\t10\t3\tE92CFF"
    private let projection =
        "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(n+0,'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(q+0,'NULL'),IFNULL(HEX(q),'NULL'),v"

    func testOriginalEncodedDefinitionScriptsAndMetadataRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.orderBy, "id+0")
        XCTAssertEqual(fixture.rowMetadata, "FULL")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        for profile in LabProfile.allCases {
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

    func testBatchesKeepMultiStatementOrderAndDeclaredGTIDCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let tables = ["matrix_exactchoices", "ex_after_insert", "ex_after_update", "ex_after_default"]
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            tables.map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.transactions, [1, 1, 2, 2, 1, 1, 1, 1, 1, 2])
        XCTAssertEqual(plan.body.transactionCount, 13)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 6)
        XCTAssertEqual(plan.expectedRows, 19)
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (length, table) in [(1, "ex_after_insert"), (2, "ex_after_update"), (3, "ex_after_default")] {
            expected += originalSQL.prefix(length).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_exactchoices", with: "poc." + table)
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

    func testEveryOldPredicateKeepsSQLAndExpectedValue() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (index, table) in ["ex_after_insert", "ex_after_update", "ex_after_default", "matrix_exactchoices"]
            .enumerated()
        {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalChecks[index].replacingOccurrences(of: "poc.matrix_exactchoices", with: "poc." + table))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testCompleteRowsKeepEncodedLabelsDefaultsAndReusedKey() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, table, value, added) in [
            ("initial-rows", "ex_after_insert", initialRows, false),
            ("updated-rows", "ex_after_update", updatedRows, false),
            ("changed-default-rows", "ex_after_default", changedRows, true),
            ("final-rows", "matrix_exactchoices", finalRows, true),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            let fields = projection + (added ? ",IFNULL(CAST(extra AS UNSIGNED),'NULL'),IFNULL(HEX(extra),'NULL')" : "")
            XCTAssertEqual(check.check.sql, fields + " FROM poc." + table + " ORDER BY id+0")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            XCTAssertTrue(
                value.split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == (added ? 15 : 13)
                })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: value], engine: engine, role: "target")
                for (old, bad) in [("F09F9880", "3F"), ("E9", "C3A9"), ("4E2D", "E4B8AD"), ("NULL", "")]
                where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [id: value.replacingOccurrences(of: old, with: bad)], engine: engine, role: "target"))
                }
            }
        }
        let final = try XCTUnwrap(plan.final.checks.first { $0.id == "final-rows" })
        XCTAssertTrue(finalRows.hasPrefix("2\t3F"))
        XCTAssertTrue(finalRows.contains("\n3\t61"))
        XCTAssertThrowsError(try final.result([final.id: changedRows], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testDefaultQueriesKeepNumericVersusQuotedDefaultsAndAddedSET() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before = try XCTUnwrap(plan.final.checks.first { $0.id == "original-default-bytes" })
        let after = try XCTUnwrap(plan.final.checks.first { $0.id == "changed-default-bytes" })
        XCTAssertEqual(before.check.expected, "61\t32\tE9\tF09F98802C61\t4E2D")
        XCTAssertEqual(after.check.expected, "32\t61\tE9\tF09F98802C61\t4E2D\tE92CFF")
        XCTAssertEqual(
            before.check.sql,
            "SELECT HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(w)) FROM poc.ex_after_insert WHERE id+0=1"
        )
        XCTAssertEqual(
            after.check.sql,
            "SELECT HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(w)),HEX(DEFAULT(extra)) FROM poc.ex_after_default WHERE id+0=1"
        )
        _ = try before.result([before.id: before.check.expected], engine: "MyISAM", role: "target")
        _ = try after.result([after.id: after.check.expected], engine: "MyISAM", role: "target")
        XCTAssertThrowsError(
            try after.result([after.id: "61\t32\tE9\tF09F98802C61\t4E2D\tE92CFF"], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try after.result(
                [after.id: after.check.expected.replacingOccurrences(of: "E92CFF", with: "FF2CE9")], engine: "MyISAM",
                role: "target"))
    }

    func testOrdinalOrderingRequiresExplicitMatchingWorkflow() throws {
        let workflow = try XCTUnwrap(fixture.workflow)
        XCTAssertEqual(workflow.order, .idOrdinal)
        XCTAssertNoThrow(try workflow.plan(fixture))
        var ordinary = workflow
        ordinary.order = .id
        XCTAssertThrowsError(try ordinary.plan(fixture))
        var test = fixture
        test.orderBy = "id"
        XCTAssertThrowsError(try workflow.plan(test))
        test.orderBy = "id DESC"
        XCTAssertThrowsError(try workflow.plan(test))
    }

    func testCleanupTitleAndOtherChoiceCasesRemain() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.final.checks.count, 10)
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ex_after_insert,poc.ex_after_update,poc.ex_after_default"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM and SET: encoded labels, numeric and quoted defaults")
        XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-exactchoices" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings", "enumzero", "choices", "widechoices",
            ])
    }
}
