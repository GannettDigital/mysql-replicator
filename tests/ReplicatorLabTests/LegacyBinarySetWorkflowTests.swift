import Foundation
import XCTest

@testable import ReplicatorLabCore

final class LegacyBinarySetWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.legacyBinarySet }
    private let definition = "id INT PRIMARY KEY,s SET(X'ff',X'61') CHARACTER SET binary DEFAULT X'ff2c61'"
    private let originalSQL = [
        "INSERT INTO poc.matrix_legacybinaryset VALUES(1,DEFAULT),(2,1),(3,2),(4,NULL)",
        "ALTER TABLE poc.matrix_legacybinaryset ALTER s SET DEFAULT X'ff'; UPDATE poc.matrix_legacybinaryset SET s=DEFAULT WHERE id=3; DELETE FROM poc.matrix_legacybinaryset WHERE id=1",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=4 AND SUM(id=1 AND s+0=3 AND HEX(s)='FF2C61')=1 AND SUM(id=2 AND HEX(s)='FF')=1 AND SUM(id=3 AND HEX(s)='61')=1 AND SUM(id=4 AND s IS NULL)=1 FROM poc.matrix_legacybinaryset",
        "SELECT COUNT(*)=3 AND SUM(id=3 AND s+0=1 AND HEX(s)='FF')=1 FROM poc.matrix_legacybinaryset",
    ]
    private let initialRows = "1\t3\tFF2C61\n2\t1\tFF\n3\t2\t61\n4\tNULL\tNULL"
    private let finalRows = "2\t1\tFF\n3\t1\tFF\n4\tNULL\tNULL"

    func testOriginalBinaryDefinitionScriptsAndVersionExclusionsRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.orderBy, "id")
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        XCTAssertEqual(
            fixture.profileExclusions,
            [
                .forward:
                    "MySQL 8.4.8 rejects this binary SET definition with native dictionary error 3507; the source cannot create it.",
                .reverse:
                    "MySQL 8.4.8 rejects this binary SET definition with native dictionary error 3507; this is a target-version limit.",
            ])
        for profile in LabProfile.allCases {
            let supported = profile == .mysql57InnoDB || profile == .mysql57MyISAM
            XCTAssertEqual(fixture.applies(to: profile), supported)
            let cold = MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile)
            XCTAssertEqual(cold.contains { $0.id == fixture.id }, supported)
            if supported {
                let original = try XCTUnwrap(cold.first { $0.id == fixture.id })
                XCTAssertEqual(Data(original.definition.utf8), Data(definition.utf8))
                XCTAssertEqual(original.phases[0].sql, originalSQL[0])
                XCTAssertEqual(original.phases[0].check, originalChecks[0])
                XCTAssertNil(original.rowMetadata)
            }
        }
    }

    func testBatchesKeepTheCompoundRequestSessionsAndSourceGTIDCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            ["matrix_legacybinaryset", "ls_after_insert"].map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        let expected =
            originalSQL.map { "USE poc; " + $0 } + [
                "USE poc; "
                    + originalSQL[0].replacingOccurrences(of: "poc.matrix_legacybinaryset", with: "poc.ls_after_insert")
            ]
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.prepare.transactions, [1, 1])
        XCTAssertEqual(plan.body.transactions, [1, 3, 1])
        XCTAssertEqual(plan.body.transactionCount, 5)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 3)
        XCTAssertEqual(plan.expectedRows, 10)
        for batch in [plan.prepare, plan.body, plan.cleanup] {
            let queries = try LabSQLPhase.queries(
                batch.writes, session: LabProfile.mysql57MyISAM.session, status: "SHOW MASTER STATUS")
            for (index, write) in batch.writes.enumerated() {
                XCTAssertTrue(queries[index * 4].sql.hasPrefix(LabProfile.mysql57MyISAM.session))
                XCTAssertTrue(queries[index * 4].sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                XCTAssertFalse(write.sql.contains("BEGIN"))
                XCTAssertFalse(write.sql.contains("COMMIT"))
            }
        }
    }

    func testBothOriginalPredicatesRemainOnTheirMatchingResults() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (index, table) in ["ls_after_insert", "matrix_legacybinaryset"].enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalChecks[index].replacingOccurrences(of: "poc.matrix_legacybinaryset", with: "poc." + table))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testCompleteRowsKeepRawBinaryMembersMasksAndNull() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, table, rows) in [
            ("initial-rows", "ls_after_insert", initialRows),
            ("final-rows", "matrix_legacybinaryset", finalRows),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(
                check.check.sql,
                "SELECT id,IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL') FROM poc." + table + " ORDER BY id")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(rows.utf8))
            XCTAssertTrue(rows.split(separator: "\n").allSatisfy { $0.split(separator: "\t").count == 3 })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([id: rows], engine: engine, role: "target")
                for (old, wrong) in [("FF", "C3BF"), ("FF", "EFBFBD"), ("NULL", ""), ("\t1\tFF", "\t2\tFF")] {
                    XCTAssertThrowsError(
                        try check.result(
                            [id: rows.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
        let final = try XCTUnwrap(plan.final.checks.first { $0.id == "final-rows" })
        XCTAssertThrowsError(try final.result([final.id: initialRows], engine: "MyISAM", role: "target"))
        XCTAssertThrowsError(
            try final.result([final.id: "2\t1\tFF\n3\t2\t61\n4\tNULL\tNULL"], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testDefaultQueriesKeepBinaryBytesAndTheAlterTransition() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for (id, sql, bytes) in [
            ("original-default-bytes", "SELECT HEX(DEFAULT(s)) FROM poc.ls_after_insert WHERE id=1", "FF2C61"),
            ("changed-default-bytes", "SELECT HEX(DEFAULT(s)) FROM poc.matrix_legacybinaryset WHERE id=2", "FF"),
        ] {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == id })
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, bytes)
            _ = try check.result([id: bytes], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(
                try check.result(
                    [id: bytes.replacingOccurrences(of: "FF", with: "C3BF")], engine: "MyISAM", role: "target"))
            XCTAssertThrowsError(try check.result([id: "61"], engine: "MyISAM", role: "target"))
        }
        let changed = try XCTUnwrap(plan.final.checks.first { $0.id == "changed-default-bytes" })
        XCTAssertThrowsError(try changed.result([changed.id: "FF2C61"], engine: "MyISAM", role: "target"))
    }

    func testCheckpointsCountEveryGTIDWithinTheCompoundRequest() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
        let end = Boundary(file: "binlog.000001", position: 1000, gtids: "uuid:1-9")
        var after: [String: Any] = [
            "transactionsApplied": 9, "ddlApplied": 4, "rowsApplied": 13, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "1000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 7
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 10
        after["ddlApplied"] = 5
        let cleaned = Boundary(file: end.file, position: 1100, gtids: "uuid:1-10")
        after["appliedGTIDSet"] = cleaned.gtids
        after["appliedPosition"] = ["file": cleaned.file, "position": "1100"]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
        after["appliedPosition"] = ["file": cleaned.file, "position": "1000"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
    }

    func testCleanupTitleAndAllSevenChoiceWorkflowsRemain() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(plan.final.checks.count, 6)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ls_after_insert"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "SET: non-UTF-8 binary members on MySQL 5.7")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-legacybinaryset" }?.test.name, fixture.displayName)
        let choiceIDs = Set([
            "choices", "widechoices", "binarychoices", "exactchoices", "enumzero", "choiceboundaries",
            "legacybinaryset",
        ])
        XCTAssertEqual(DMLCompatibilityCases.cases.filter { choiceIDs.contains($0.id) && $0.workflow != nil }.count, 7)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "binarydefaults", "textdefaults", "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings",
                "spatial", "json", "typedjson", "floatbounds", "zerofill", "fixedfloating", "floating",
                "bits", "fixed", "enumzero", "choices", "widechoices", "integers", "decimal", "temporal", "precision",
                "lob",
                "defaults",
                "floatingautofloat", "floatingautodouble", "floatingautofixedfloat", "floatingautounsigneddouble",
            ])
    }
}
