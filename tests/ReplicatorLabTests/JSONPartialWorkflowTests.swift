import Foundation
import XCTest

@testable import ReplicatorLabCore

final class JSONPartialWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "jsonpartial", definition: "id INT PRIMARY KEY,doc JSON",
            sql: [
                "INSERT INTO poc.matrix_jsonpartial VALUES(1,JSON_OBJECT('padding',REPEAT('x',1000),'a',JSON_ARRAY(1,2,3),'d',CAST('1.00' AS DECIMAL(3,2))))",
                "SET SESSION binlog_row_value_options='PARTIAL_JSON'; UPDATE poc.matrix_jsonpartial SET doc=JSON_SET(doc,'$.a[1]',CAST('123.45' AS DECIMAL(5,2)),'$.d',CAST('2024-02-29' AS DATE)) WHERE id=1",
                "SET SESSION binlog_row_value_options='PARTIAL_JSON'; UPDATE poc.matrix_jsonpartial SET doc=JSON_REMOVE(doc,'$.a[0]') WHERE id=1",
                "DELETE FROM poc.matrix_jsonpartial",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_LENGTH(JSON_EXTRACT(doc,'$.a'))=3",
                "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_TYPE(JSON_EXTRACT(doc,'$.a[1]'))='DECIMAL' AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.a[1]'))='123.45' AND JSON_TYPE(JSON_EXTRACT(doc,'$.d'))='DATE'",
                "SELECT COUNT(*)=1 FROM poc.matrix_jsonpartial WHERE JSON_LENGTH(JSON_EXTRACT(doc,'$.a'))=2 AND JSON_TYPE(JSON_EXTRACT(doc,'$.a[0]'))='DECIMAL'",
                "SELECT COUNT(*)=0 FROM poc.matrix_jsonpartial",
            ])
    ]
    private func fixture(_ id: String) throws -> DMLCompatibilityCases.Case {
        try XCTUnwrap(DMLCompatibilityCases.cases.first { $0.id == id })
    }
    private func plan(_ id: String) throws -> DMLExecutionWorkflow.Plan {
        let test = try fixture(id)
        return try XCTUnwrap(test.workflow).plan(test)
    }
    private func check(_ id: String, _ name: String) throws -> DDLFinalObservations.Observation {
        try XCTUnwrap(plan(id).final.checks.first { $0.id == name })
    }

    func testOriginalDefinitionsRequestsAndPredicatesRemain() throws {
        for original in originals {
            let test = try fixture(original.id)
            XCTAssertEqual(Data(test.definition.utf8), Data(original.definition.utf8))
            XCTAssertEqual(test.phases.map { Data($0.sql.utf8) }, original.sql.map { Data($0.utf8) })
            XCTAssertEqual(test.phases.map(\.check), original.predicates)
            XCTAssertTrue(test.setup.isEmpty)
            XCTAssertEqual(test.orderBy, "id")
            XCTAssertNil(test.rowMetadata)
            XCTAssertNil(test.replicatedReplacement)
            XCTAssertTrue(test.profileExclusions.isEmpty)
            XCTAssertEqual(test.phases.map(\.expectsJSONDiff), [false, true, true, false])
        }
    }

    func testForwardScopeAndColdJSONRepresentativeRemain() throws {
        let test = try fixture("jsonpartial")
        XCTAssertNotNil(test.source84OnlyReason)
        XCTAssertEqual(MetadataDiscoveryCases.representative("jsonpartial"), "json")
        for profile in LabProfile.allCases {
            XCTAssertEqual(test.applies(to: profile), profile == .forward)
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == "json"
                })
            XCTAssertEqual(cold.definition, test.definition)
        }
    }

    func testBatchesPreserveCompoundSQLSessionResetsAndSourceTransactionCounts() throws {
        for (original, histories, counts) in zipOriginals() {
            let plan = try plan(original.id)
            XCTAssertEqual(
                plan.prepare.writes.map(\.sql),
                (["matrix_" + original.id] + histories).map {
                    "CREATE TABLE poc." + $0 + "(" + original.definition
                        + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
                })
            XCTAssertEqual(plan.prepare.transactions, Array(repeating: 1, count: histories.count + 1))
            var expected = original.sql.map { "USE poc; " + $0 }
            var transactions = counts
            for (index, table) in histories.enumerated() {
                expected += original.sql.prefix(index + 1).map {
                    "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_" + original.id, with: "poc." + table)
                }
                transactions += counts.prefix(index + 1)
            }
            XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertEqual(plan.body.transactions, transactions)
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
    }

    private func zipOriginals() -> [(Original, [String], [Int])] {
        [(originals[0], ["jp_after_insert", "jp_after_replace", "jp_after_remove"], [1, 1, 1, 1])]
    }

    func testEveryOriginalPredicateObservesItsMatchingRetainedResult() throws {
        for (original, histories, _) in zipOriginals() {
            let plan = try plan(original.id)
            for (index, table) in (histories + ["matrix_" + original.id]).enumerated() {
                let check = plan.final.checks[index]
                XCTAssertEqual(
                    check.check.sql,
                    original.predicates[index].replacingOccurrences(
                        of: "poc.matrix_" + original.id, with: "poc." + table))
                XCTAssertEqual(check.check.expected, "1")
                _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
                XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testRetainedResultsKeepPaddingNativeTypesExactDecimalsAndRemovedIndex() throws {
        for (name, sql, value) in [
            (
                "initial-json-values",
                "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_insert ORDER BY id",
                "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t3\tINTEGER\t1\tINTEGER\t2\tINTEGER\t3\tDECIMAL\t1.00"
            ),
            (
                "replaced-json-values",
                "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_replace ORDER BY id",
                "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t3\tINTEGER\t1\tDECIMAL\t123.45\tINTEGER\t3\tDATE\t2024-02-29"
            ),
            (
                "removed-array-element-values",
                "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_remove ORDER BY id",
                "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t2\tDECIMAL\t123.45\tINTEGER\t3\tSQL_NULL\tSQL_NULL\tDATE\t2024-02-29"
            ),
            ("empty-final-table", "SELECT id FROM poc.matrix_jsonpartial ORDER BY id", ""),
        ] {
            let check = try check("jsonpartial", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            for (old, wrong) in [
                ("1.00", "1"), ("DECIMAL", "DOUBLE"), ("DATE", "STRING"), ("1000", "999"), ("123.45", "123.46"),
                ("SQL_NULL", "NULL"),
            ] where value.contains(old) {
                XCTAssertThrowsError(
                    try check.result(
                        [name: value.replacingOccurrences(of: old, with: wrong)], engine: "MyISAM", role: "target"))
            }
            XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: "MyISAM", role: "target"))
        }
    }

    func testExplicitEventPlanCoversOriginalAndRetainedUpdatesOnly() throws {
        let test = try fixture("jsonpartial")
        let workflow = try XCTUnwrap(test.workflow)
        XCTAssertEqual(workflow.jsonDiffPhases.map(\.phase), [2, 3])
        XCTAssertEqual(workflow.jsonDiffPhases.map(\.operation), [.replace, .remove])
        let plan = try workflow.plan(test)
        XCTAssertTrue(plan.prepare.jsonDiffChecks.isEmpty)
        XCTAssertTrue(plan.cleanup.jsonDiffChecks.isEmpty)
        XCTAssertEqual(
            plan.body.jsonDiffChecks.map(\.writeID),
            [
                "original-phase-2", "original-phase-3", "jp_after_replace-phase-2", "jp_after_remove-phase-2",
                "jp_after_remove-phase-3",
            ])
        XCTAssertEqual(
            plan.body.jsonDiffChecks.map(\.table),
            [
                "poc.matrix_jsonpartial", "poc.matrix_jsonpartial", "poc.jp_after_replace", "poc.jp_after_remove",
                "poc.jp_after_remove",
            ])
        XCTAssertEqual(plan.body.jsonDiffChecks.map(\.operation), [.replace, .remove, .replace, .replace, .remove])
        for check in plan.body.jsonDiffChecks {
            let write = try XCTUnwrap(plan.body.writes.first { $0.id == check.writeID })
            XCTAssertTrue(
                write.sql.contains("SET SESSION binlog_row_value_options='PARTIAL_JSON'; UPDATE " + check.table))
        }
    }

    func testDiffGuardRejectsMissingExtraDuplicateAndMultiTransactionPhases() throws {
        let test = try fixture("jsonpartial")
        let original = try XCTUnwrap(test.workflow)
        for phases: [LabJSONDiff.Phase] in [
            [], [.init(phase: 2, operation: .replace)],
            [.init(phase: 1, operation: .replace), .init(phase: 3, operation: .remove)],
            [.init(phase: 2, operation: .replace), .init(phase: 2, operation: .replace)],
            [.init(phase: 3, operation: .remove), .init(phase: 2, operation: .replace)],
            [.init(phase: 0, operation: .remove)], [.init(phase: 9, operation: .remove)],
        ] {
            var invalid = original
            invalid.jsonDiffPhases = phases
            XCTAssertThrowsError(try invalid.plan(test))
        }
        let invalid = DMLExecutionWorkflow(
            title: original.title, histories: original.histories, phaseTransactions: [1, 2, 1, 1],
            predicateIDs: original.predicateIDs, additionalChecks: original.additionalChecks,
            expectedDDL: original.expectedDDL, expectedRows: original.expectedRows,
            jsonDiffPhases: original.jsonDiffPhases)
        XCTAssertThrowsError(try invalid.plan(test))
    }

    func testProgressRejectsWrongCountsGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("jsonpartial", 14, 4, 10)
        ] {
            let plan = try plan(id)
            XCTAssertEqual(plan.expectedDDL, ddl)
            XCTAssertEqual(plan.expectedRows, rows)
            let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
            for cleaned in [false, true] {
                let n = transactions + (cleaned ? 1 : 0)
                let end = Boundary(file: "binlog.000003", position: 1000, gtids: "uuid:1-\(n+2)")
                let after: [String: Any] = [
                    "transactionsApplied": n + 2, "ddlApplied": ddl + 1 + (cleaned ? 1 : 0), "rowsApplied": rows + 3,
                    "appliedGTIDSet": end.gtids, "appliedPosition": ["file": end.file, "position": "1000"],
                ]
                XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: cleaned))
                for key in ["transactionsApplied", "ddlApplied", "rowsApplied"] {
                    var wrong = after
                    wrong[key] = try XCTUnwrap(after[key] as? Int) - 1
                    XCTAssertThrowsError(
                        try plan.validateProgress(before: before, after: wrong, end: end, cleaned: cleaned))
                }
                var wrong = after
                wrong["appliedGTIDSet"] = "uuid:1-2"
                XCTAssertThrowsError(
                    try plan.validateProgress(before: before, after: wrong, end: end, cleaned: cleaned))
                wrong = after
                wrong["appliedPosition"] = ["file": end.file, "position": "999"]
                XCTAssertThrowsError(
                    try plan.validateProgress(before: before, after: wrong, end: end, cleaned: cleaned))
            }
        }
    }

    func testCleanupSharedTitlesAndGlobalMembershipRemain() throws {
        for (original, histories, _) in zipOriginals() {
            let plan = try plan(original.id)
            XCTAssertEqual(plan.final.databases, ["poc"])
            XCTAssertEqual(
                plan.cleanup.writes.map(\.sql), ["DROP TABLE " + histories.map { "poc." + $0 }.joined(separator: ",")])
            XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
            XCTAssertEqual(plan.cleanup.transactions, [1])
            XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
            let expected = ["jsonpartial": 8]
            XCTAssertEqual(plan.final.checks.count, expected[original.id])
            XCTAssertEqual(
                LabScenario.correctness.first { $0.id == "matrix-" + original.id }?.test.name,
                try fixture(original.id).displayName)
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "binarydefaults", "textdefaults", "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings", "spatial", "json", "typedjson", "jsonpartial",
                "floatbounds",
                "zerofill",
                "fixedfloating",
                "floating", "bits", "fixed", "enumzero", "choices", "widechoices", "integers", "decimal", "temporal",
                "precision", "lob", "defaults", "floatingautofloat", "floatingautodouble", "floatingautofixedfloat",
                "floatingautounsigneddouble",
            ])
    }
}
