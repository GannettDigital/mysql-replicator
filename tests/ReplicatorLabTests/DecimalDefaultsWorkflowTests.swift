import Foundation
import XCTest

@testable import ReplicatorLabCore

final class DecimalDefaultsWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case { DMLCompatibilityCases.decimalDefaults }
    private let definition =
        "id INT PRIMARY KEY,a DECIMAL(8,2) DEFAULT 1.235,b DECIMAL(8,2) DEFAULT -1.235,c DECIMAL(8,2) DEFAULT 1.005e0,d DECIMAL(8,2) DEFAULT '1.005e0',z DECIMAL(8,2) ZEROFILL DEFAULT 9.999,u DECIMAL(8,2) UNSIGNED DEFAULT 0.005,n DECIMAL(8,0) DEFAULT -0.4"
    private let originalSQL = [
        "INSERT INTO poc.matrix_decimaldefaults(id) VALUES(1),(2)",
        "ALTER TABLE poc.matrix_decimaldefaults ALTER a SET DEFAULT 2.345,ALTER b SET DEFAULT '-2.345',ALTER c SET DEFAULT 2.675e0,ADD extra DECIMAL(8,2) DEFAULT 9.995; UPDATE poc.matrix_decimaldefaults SET a=DEFAULT,b=DEFAULT,c=DEFAULT WHERE id=1",
        "ALTER TABLE poc.matrix_decimaldefaults MODIFY d DECIMAL(10,3) DEFAULT '1.2345',ALTER u DROP DEFAULT; INSERT INTO poc.matrix_decimaldefaults(id,u) VALUES(3,NULL); DELETE FROM poc.matrix_decimaldefaults WHERE id=2",
    ]
    private let originalPredicates = [
        "SELECT COUNT(*)=2 AND SUM(a=1.24 AND b=-1.24 AND c=1.01 AND d=1.01 AND z=10 AND u=0.01 AND n=0)=2 FROM poc.matrix_decimaldefaults",
        "SELECT COUNT(*)=2 AND SUM(id=1 AND a=2.35 AND b=-2.35 AND c=2.68)=1 AND SUM(extra=10)=2 FROM poc.matrix_decimaldefaults",
        "SELECT COUNT(*)=2 AND SUM(id=3 AND d=1.235 AND u IS NULL AND extra=10)=1 FROM poc.matrix_decimaldefaults",
    ]
    private func plan() throws -> DMLExecutionWorkflow.Plan {
        try XCTUnwrap(fixture.workflow).plan(fixture)
    }
    private func check(_ id: String) throws -> DDLFinalObservations.Observation {
        try XCTUnwrap(plan().final.checks.first { $0.id == id })
    }

    func testOriginalSQLAndColdMetadataRemainOnEveryProfile() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalPredicates)
        XCTAssertNil(fixture.rowMetadata)
        XCTAssertEqual(fixture.orderBy, "id")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        XCTAssertEqual(MetadataDiscoveryCases.representative(fixture.id), fixture.id)
        XCTAssertEqual(MetadataDiscoveryCases.owner(fixture.id), MetadataDiscoveryCases.columns.id)
        for profile in LabProfile.allCases {
            XCTAssertTrue(fixture.applies(to: profile))
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == fixture.id
                })
            XCTAssertEqual(Data(cold.definition.utf8), Data(definition.utf8))
            XCTAssertEqual(cold.phases[0].sql, originalSQL[0])
            XCTAssertEqual(cold.phases[0].check, originalPredicates[0])
            XCTAssertNil(cold.rowMetadata)
        }
    }

    func testBatchesKeepCompoundRequestsGTIDCountsAndSessionResets() throws {
        let plan = try plan()
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            ["matrix_decimaldefaults", "dd_after_insert", "dd_after_defaults"].map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        let expected =
            originalSQL.map { "USE poc; " + $0 }
            + [
                "USE poc; "
                    + originalSQL[0].replacingOccurrences(of: "poc.matrix_decimaldefaults", with: "poc.dd_after_insert")
            ]
            + originalSQL.prefix(2).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_decimaldefaults", with: "poc.dd_after_defaults")
            }
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.prepare.transactions, [1, 1, 1])
        XCTAssertEqual(plan.body.transactions, [1, 2, 3, 1, 1, 2])
        XCTAssertEqual(plan.body.transactionCount, 10)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 6)
        XCTAssertEqual(plan.expectedRows, 10)
        for batch in [plan.prepare, plan.body, plan.cleanup] {
            let queries = try LabSQLPhase.queries(
                batch.writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
            for (index, write) in batch.writes.enumerated() {
                XCTAssertTrue(queries[index * 4].sql.hasPrefix(LabProfile.forward.session + "\n"))
                XCTAssertTrue(queries[index * 4].sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                XCTAssertFalse(write.sql.contains("BEGIN"))
                XCTAssertFalse(write.sql.contains("COMMIT"))
            }
        }
    }

    func testEveryOriginalPredicateRemainsOnItsMatchingResult() throws {
        let plan = try plan()
        for (index, table) in ["dd_after_insert", "dd_after_defaults", "matrix_decimaldefaults"].enumerated() {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalPredicates[index].replacingOccurrences(of: "poc.matrix_decimaldefaults", with: "poc." + table))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testCompleteRowsKeepSignedRoundingAddedDefaultsAndChangedScale() throws {
        for (name, table, value, added, changedScale) in [
            (
                "initial-rows", "dd_after_insert",
                "1\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0\n2\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0", false, false
            ),
            (
                "changed-defaults-rows", "dd_after_defaults",
                "1\t2.35\t-2.35\t2.68\t1.01\t10.00\t0.01\t0\t10.00\n2\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0\t10.00",
                true, false
            ),
            (
                "final-rows", "matrix_decimaldefaults",
                "1\t2.35\t-2.35\t2.68\t1.010\t10.00\t0.01\t0\t10.00\n3\t2.35\t-2.35\t2.68\t1.235\t10.00\tNULL\t0\t10.00",
                true, true
            ),
        ] {
            let check = try check(name)
            let fields = ["a", "b", "c", "d", "z", "u", "n"] + (added ? ["extra"] : [])
            let projection = fields.map { field in
                let precision = field == "n" ? "8,0" : field == "d" && changedScale ? "10,3" : "8,2"
                return "IFNULL(CAST(" + field + " AS DECIMAL(" + precision + ")),'NULL')"
            }.joined(separator: ",")
            XCTAssertEqual(check.check.sql, "SELECT id," + projection + " FROM poc." + table + " ORDER BY id")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                for (old, wrong) in [
                    ("1.24", "1.23"), ("-2.35", "-2.34"), ("2.68", "2.67"), ("10.00", "9.99"), ("1.010", "1.01"),
                    ("NULL", "0.00"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testStoredDefaultsAndDeclaredAttributesStayIndependentFromRows() throws {
        for (prefix, table, defaults, added, final) in [
            ("initial", "dd_after_insert", "1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0", false, false),
            ("changed-defaults", "dd_after_defaults", "2.35\t-2.35\t2.68\t1.01\t10.00\t0.01\t0\t10.00", true, false),
            ("final", "matrix_decimaldefaults", "2.35\t-2.35\t2.68\t1.235\t10.00\t0\t10.00", true, true),
        ] {
            let check = try check(prefix + "-stored-defaults")
            let fields = ["a", "b", "c", "d", "z"] + (final ? [] : ["u"]) + ["n"] + (added ? ["extra"] : [])
            let projection = fields.map { field in
                let precision = field == "n" ? "8,0" : field == "d" && final ? "10,3" : "8,2"
                return "IFNULL(CAST(DEFAULT(" + field + ") AS DECIMAL(" + precision + ")),'NULL')"
            }.joined(separator: ",")
            XCTAssertEqual(check.check.sql, "SELECT " + projection + " FROM poc." + table + " WHERE id=1")
            XCTAssertEqual(check.check.expected, defaults)
            XCTAssertEqual(check.check.sql.contains("DEFAULT(u)"), !final)
            _ = try check.result([check.id: defaults], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: defaults + "0"], engine: "MyISAM", role: "target"))
            let schema = try self.check(prefix + "-column-attributes")
            XCTAssertEqual(
                schema.check.sql,
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='"
                    + table + "' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION")
            let expected =
                "a\tdecimal(8,2)\tYES\t0\nb\tdecimal(8,2)\tYES\t0\nc\tdecimal(8,2)\tYES\t0\nd\tdecimal(\(final ? "10,3" : "8,2"))\tYES\t0\nz\tdecimal(8,2) unsigned zerofill\tYES\t0\nu\tdecimal(8,2) unsigned\tYES\t\(final ? "1" : "0")\nn\tdecimal(8,0)\tYES\t0"
                + (added ? "\nextra\tdecimal(8,2)\tYES\t0" : "")
            XCTAssertEqual(schema.check.expected, expected)
            _ = try schema.result([schema.id: expected], engine: "MyISAM", role: "target")
            for wrong in [
                expected.replacingOccurrences(of: " unsigned zerofill", with: ""),
                expected.replacingOccurrences(of: "decimal(8,2) unsigned", with: "decimal(8,2)"),
            ] {
                XCTAssertThrowsError(try schema.result([schema.id: wrong], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testProgressRequiresExactCountersGTIDsAndOffsets() throws {
        let plan = try plan()
        let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
        let end = Boundary(file: "binlog.000001", position: 1000, gtids: "uuid:1-15")
        var after: [String: Any] = [
            "transactionsApplied": 15, "ddlApplied": 7, "rowsApplied": 13, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "1000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 11
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 16
        after["ddlApplied"] = 8
        after["appliedGTIDSet"] = "uuid:1-16"
        let cleaned = Boundary(file: end.file, position: end.position, gtids: "uuid:1-16")
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
        after["appliedPosition"] = ["file": end.file, "position": "999"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
    }

    func testCleanupTitleAndOtherFixtureMembershipRemain() throws {
        let plan = try plan()
        XCTAssertEqual(plan.final.checks.count, 12)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.dd_after_insert,poc.dd_after_defaults"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(fixture.displayName, "Fixed-point types: DECIMAL default rounding and scale changes")
        XCTAssertEqual(
            LabScenario.correctness.first { $0.id == "matrix-decimaldefaults" }?.test.name, fixture.displayName)
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
