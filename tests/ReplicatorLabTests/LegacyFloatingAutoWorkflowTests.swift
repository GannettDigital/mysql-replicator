import Foundation
import XCTest

@testable import ReplicatorLabCore

final class LegacyFloatingAutoWorkflowTests: XCTestCase {
    private struct Original {
        let suffix: String
        let type: String
        let definition: String
        let sql: [String]
        let predicates: [String]
        var id: String { "floatingauto" + suffix }
        var histories: [String] { ["insert", "update", "alter"].map { "fai_" + suffix + "_" + $0 } }
    }
    private let originals: [Original] = [
        .init(
            suffix: "float", type: "FLOAT", definition: "id FLOAT AUTO_INCREMENT PRIMARY KEY,v INT",
            sql: [
                "INSERT INTO poc.matrix_floatingautofloat VALUES(NULL,11),(NULL,22),(0,33)",
                "UPDATE poc.matrix_floatingautofloat SET id=9.5,v=110 WHERE id=1; INSERT INTO poc.matrix_floatingautofloat VALUES(100,44),(NULL,55)",
                "ALTER TABLE poc.matrix_floatingautofloat ADD extra INT DEFAULT 7; UPDATE poc.matrix_floatingautofloat SET id=102,extra=8 WHERE id=101",
                "DELETE FROM poc.matrix_floatingautofloat WHERE id IN (0,2)",
            ],
            predicates: [
                "SELECT COUNT(*)=3 AND SUM(id=0)=1 AND SUM(id=1)=1 AND SUM(id=2)=1 FROM poc.matrix_floatingautofloat",
                "SELECT COUNT(*)=5 AND SUM(id=9.5 AND v=110)=1 AND SUM(id=101 AND v=55)=1 FROM poc.matrix_floatingautofloat",
                "SELECT COUNT(*)=1 FROM poc.matrix_floatingautofloat WHERE id=102 AND extra=8",
                "SELECT COUNT(*)=3 AND SUM(id=9.5)=1 AND SUM(id=100)=1 AND SUM(id=102)=1 FROM poc.matrix_floatingautofloat",
            ]),
        .init(
            suffix: "double", type: "DOUBLE", definition: "id DOUBLE AUTO_INCREMENT PRIMARY KEY,v INT",
            sql: [
                "INSERT INTO poc.matrix_floatingautodouble VALUES(NULL,11),(NULL,22),(0,33)",
                "UPDATE poc.matrix_floatingautodouble SET id=9.5,v=110 WHERE id=1; INSERT INTO poc.matrix_floatingautodouble VALUES(100,44),(NULL,55)",
                "ALTER TABLE poc.matrix_floatingautodouble ADD extra INT DEFAULT 7; UPDATE poc.matrix_floatingautodouble SET id=102,extra=8 WHERE id=101",
                "DELETE FROM poc.matrix_floatingautodouble WHERE id IN (0,2)",
            ],
            predicates: [
                "SELECT COUNT(*)=3 AND SUM(id=0)=1 AND SUM(id=1)=1 AND SUM(id=2)=1 FROM poc.matrix_floatingautodouble",
                "SELECT COUNT(*)=5 AND SUM(id=9.5 AND v=110)=1 AND SUM(id=101 AND v=55)=1 FROM poc.matrix_floatingautodouble",
                "SELECT COUNT(*)=1 FROM poc.matrix_floatingautodouble WHERE id=102 AND extra=8",
                "SELECT COUNT(*)=3 AND SUM(id=9.5)=1 AND SUM(id=100)=1 AND SUM(id=102)=1 FROM poc.matrix_floatingautodouble",
            ]),
        .init(
            suffix: "fixedfloat", type: "FLOAT(10,2)", definition: "id FLOAT(10,2) AUTO_INCREMENT PRIMARY KEY,v INT",
            sql: [
                "INSERT INTO poc.matrix_floatingautofixedfloat VALUES(NULL,11),(NULL,22),(0,33)",
                "UPDATE poc.matrix_floatingautofixedfloat SET id=9.5,v=110 WHERE id=1; INSERT INTO poc.matrix_floatingautofixedfloat VALUES(100,44),(NULL,55)",
                "ALTER TABLE poc.matrix_floatingautofixedfloat ADD extra INT DEFAULT 7; UPDATE poc.matrix_floatingautofixedfloat SET id=102,extra=8 WHERE id=101",
                "DELETE FROM poc.matrix_floatingautofixedfloat WHERE id IN (0,2)",
            ],
            predicates: [
                "SELECT COUNT(*)=3 AND SUM(id=0)=1 AND SUM(id=1)=1 AND SUM(id=2)=1 FROM poc.matrix_floatingautofixedfloat",
                "SELECT COUNT(*)=5 AND SUM(id=9.5 AND v=110)=1 AND SUM(id=101 AND v=55)=1 FROM poc.matrix_floatingautofixedfloat",
                "SELECT COUNT(*)=1 FROM poc.matrix_floatingautofixedfloat WHERE id=102 AND extra=8",
                "SELECT COUNT(*)=3 AND SUM(id=9.5)=1 AND SUM(id=100)=1 AND SUM(id=102)=1 FROM poc.matrix_floatingautofixedfloat",
            ]),
        .init(
            suffix: "unsigneddouble", type: "DOUBLE UNSIGNED",
            definition: "id DOUBLE UNSIGNED AUTO_INCREMENT PRIMARY KEY,v INT",
            sql: [
                "INSERT INTO poc.matrix_floatingautounsigneddouble VALUES(NULL,11),(NULL,22),(0,33)",
                "UPDATE poc.matrix_floatingautounsigneddouble SET id=9.5,v=110 WHERE id=1; INSERT INTO poc.matrix_floatingautounsigneddouble VALUES(100,44),(NULL,55)",
                "ALTER TABLE poc.matrix_floatingautounsigneddouble ADD extra INT DEFAULT 7; UPDATE poc.matrix_floatingautounsigneddouble SET id=102,extra=8 WHERE id=101",
                "DELETE FROM poc.matrix_floatingautounsigneddouble WHERE id IN (0,2)",
            ],
            predicates: [
                "SELECT COUNT(*)=3 AND SUM(id=0)=1 AND SUM(id=1)=1 AND SUM(id=2)=1 FROM poc.matrix_floatingautounsigneddouble",
                "SELECT COUNT(*)=5 AND SUM(id=9.5 AND v=110)=1 AND SUM(id=101 AND v=55)=1 FROM poc.matrix_floatingautounsigneddouble",
                "SELECT COUNT(*)=1 FROM poc.matrix_floatingautounsigneddouble WHERE id=102 AND extra=8",
                "SELECT COUNT(*)=3 AND SUM(id=9.5)=1 AND SUM(id=100)=1 AND SUM(id=102)=1 FROM poc.matrix_floatingautounsigneddouble",
            ]),
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

    func testOriginalDefinitionsRequestsPredicatesAndMetadataFlagsRemain() throws {
        for original in originals {
            let test = try fixture(original.id)
            XCTAssertEqual(Data(test.definition.utf8), Data(original.definition.utf8))
            XCTAssertEqual(test.phases.map { Data($0.sql.utf8) }, original.sql.map { Data($0.utf8) })
            XCTAssertEqual(test.phases.map(\.check), original.predicates)
            XCTAssertTrue(test.setup.isEmpty)
            XCTAssertEqual(test.orderBy, "id")
            XCTAssertNil(test.rowMetadata)
            XCTAssertNil(test.replicatedReplacement)
            XCTAssertNil(test.source84OnlyReason)
            XCTAssertFalse(test.phases.contains(where: \.expectsJSONDiff))
            XCTAssertEqual(Set(test.profileExclusions.keys), Set([LabProfile.forward, .reverse]))
            XCTAssertEqual(
                test.profileExclusions[.forward],
                "MySQL 8.4 rejects FLOAT/DOUBLE AUTO_INCREMENT with native error 1063; the source cannot create this schema."
            )
            XCTAssertEqual(
                test.profileExclusions[.reverse],
                "MySQL 8.4 rejects FLOAT/DOUBLE AUTO_INCREMENT with native error 1063; this is a target-version limit.")
        }
    }

    func testColdMetadataAndVersionExclusionsRemainOnBothExecutionPaths() throws {
        for original in originals {
            let test = try fixture(original.id)
            let scenario = try XCTUnwrap(LabScenario.correctness.first { $0.id == "matrix-" + original.id })
            XCTAssertEqual(MetadataDiscoveryCases.owner(original.id), MetadataDiscoveryCases.columns.id)
            XCTAssertEqual(MetadataDiscoveryCases.representative(original.id), original.id)
            for profile in LabProfile.allCases {
                let allowed = profile == .mysql57MyISAM || profile == .mysql57InnoDB
                XCTAssertEqual(test.applies(to: profile), allowed)
                let cold = MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == original.id
                }
                XCTAssertEqual(cold != nil, allowed)
                if allowed {
                    let cold = try XCTUnwrap(cold)
                    XCTAssertEqual(Data(cold.definition.utf8), Data(original.definition.utf8))
                    XCTAssertEqual(cold.phases[0].sql, original.sql[0])
                    XCTAssertEqual(cold.phases[0].check, original.predicates[0])
                    XCTAssertNil(cold.rowMetadata)
                    XCTAssertNil(scenario.reason(profile, variant: .standard))
                } else {
                    XCTAssertTrue(try XCTUnwrap(scenario.reason(profile, variant: .standard)).contains("1063"))
                }
            }
        }
    }

    func testSourceBatchesKeepCompoundRequestsAndTransactionCounts() throws {
        for original in originals {
            let plan = try plan(original.id)
            XCTAssertEqual(
                plan.prepare.writes.map(\.sql),
                (["matrix_" + original.id] + original.histories).map {
                    "CREATE TABLE poc." + $0 + "(" + original.definition
                        + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
                })
            XCTAssertEqual(plan.prepare.transactions, [1, 1, 1, 1])
            var expected = original.sql.map { "USE poc; " + $0 }
            for (index, table) in original.histories.enumerated() {
                expected += original.sql.prefix(index + 1).map {
                    "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_" + original.id, with: "poc." + table)
                }
            }
            XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertEqual(plan.body.transactions, [1, 2, 2, 1, 1, 1, 2, 1, 2, 2])
            XCTAssertEqual(plan.body.transactionCount, 15)
            XCTAssertEqual(plan.cleanup.transactionCount, 1)
            for batch in [plan.prepare, plan.body, plan.cleanup] {
                let session = LabProfile.mysql57MyISAM.session
                XCTAssertTrue(session.contains("NO_AUTO_VALUE_ON_ZERO"))
                let queries = try LabSQLPhase.queries(batch.writes, session: session, status: "SHOW MASTER STATUS")
                for (index, write) in batch.writes.enumerated() {
                    XCTAssertTrue(queries[index * 4].sql.hasPrefix(session + "\n"))
                    XCTAssertTrue(queries[index * 4].sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                    XCTAssertFalse(write.sql.contains("BEGIN"))
                    XCTAssertFalse(write.sql.contains("COMMIT"))
                }
            }
        }
    }

    func testEveryOriginalPredicateKeepsItsMatchingRetainedResult() throws {
        for original in originals {
            let plan = try plan(original.id)
            for (index, table) in (original.histories + ["matrix_" + original.id]).enumerated() {
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

    func testCompleteRowsRetainZeroGeneratedIDsFractionalKeysAndDeletions() throws {
        let values = [
            "0.00\t33\n1.00\t11\n2.00\t22",
            "0.00\t33\n2.00\t22\n9.50\t110\n100.00\t44\n101.00\t55",
            "0.00\t33\t7\n2.00\t22\t7\n9.50\t110\t7\n100.00\t44\t7\n102.00\t55\t8",
            "9.50\t110\t7\n100.00\t44\t7\n102.00\t55\t8",
        ]
        for original in originals {
            for (index, name) in ["initial-rows", "updated-rows", "altered-rows", "final-rows"].enumerated() {
                let table = (original.histories + ["matrix_" + original.id])[index]
                let check = try check(original.id, name)
                XCTAssertEqual(
                    check.check.sql,
                    "SELECT CAST(id AS DECIMAL(12,2)),IFNULL(CAST(v AS CHAR),'NULL')"
                        + (index >= 2 ? ",IFNULL(CAST(extra AS CHAR),'NULL')" : "") + " FROM poc." + table
                        + " ORDER BY id")
                let value = values[index]
                XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
                for engine in ["InnoDB", "MyISAM"] {
                    _ = try check.result([name: value], engine: engine, role: "target")
                    XCTAssertThrowsError(try check.result([name: value + "\n0.00\t33"], engine: engine, role: "target"))
                    for (old, wrong) in [
                        ("0.00", "1.00"), ("9.50", "9.00"), ("101.00", "100.00"), ("102.00", "101.00"), ("110", "11"),
                        ("\t7", "\t0"),
                    ] where value.contains(old) {
                        XCTAssertThrowsError(
                            try check.result(
                                [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"
                            ))
                    }
                }
            }
        }
    }

    func testAutoIncrementDeclarationNullabilityAndAddedDefaultRemain() throws {
        for original in originals {
            for (index, name) in ["initial-column-attributes", "altered-column-attributes"].enumerated() {
                let table = original.histories[index == 0 ? 0 : 2]
                let check = try check(original.id, name)
                let value =
                    "id\t" + original.type.lowercased() + "\tNO\t1\nv\tint\tYES\t0"
                    + (index == 1 ? "\nextra\tint\tYES\t0" : "")
                XCTAssertEqual(
                    check.check.sql,
                    "SELECT COLUMN_NAME,IF(COLUMN_NAME='id',COLUMN_TYPE,DATA_TYPE),IS_NULLABLE,EXTRA='auto_increment' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='"
                        + table + "' ORDER BY ORDINAL_POSITION")
                XCTAssertEqual(check.check.expected, value)
                _ = try check.result([name: value], engine: "MyISAM", role: "target")
                for wrong in [
                    value.replacingOccurrences(of: "NO\t1", with: "NO\t0"),
                    value.replacingOccurrences(of: "NO\t1", with: "YES\t1"),
                ] {
                    XCTAssertThrowsError(try check.result([name: wrong], engine: "MyISAM", role: "target"))
                }
            }
            let added = try check(original.id, "added-column-default")
            XCTAssertEqual(added.check.sql, "SELECT DEFAULT(extra) FROM poc." + original.histories[2] + " WHERE id=102")
            XCTAssertEqual(added.check.expected, "7")
            XCTAssertThrowsError(try added.result([added.id: "8"], engine: "MyISAM", role: "target"))
        }
    }

    func testNextGeneratedValuesAllowReservedGapsAndExceedStoredKeys() throws {
        for original in originals {
            let tables = original.histories + ["matrix_" + original.id]
            let minimums = [3, 102, 103, 103]
            let expected = tables.sorted().map { $0 + "\t1" }.joined(separator: "\n")
            let check = try check(original.id, "next-values-exceed-retained-keys")
            let bounds = zip(tables, minimums).map { "WHEN '" + $0 + "' THEN " + String($1) }.joined(separator: " ")
            XCTAssertEqual(
                check.check.sql,
                "SELECT TABLE_NAME,AUTO_INCREMENT>=CASE TABLE_NAME " + bounds
                    + " END FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME IN ("
                    + tables.map { "'" + $0 + "'" }.joined(separator: ",") + ") ORDER BY BINARY TABLE_NAME")
            XCTAssertEqual(check.check.expected, expected)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([check.id: expected], engine: engine, role: "target")
                for wrong in [
                    expected.replacingOccurrences(of: "\t1", with: "\t0"),
                    expected.replacingOccurrences(of: "\t1", with: "\tNULL"),
                    expected.components(separatedBy: "\n").dropLast().joined(separator: "\n"),
                ] {
                    XCTAssertThrowsError(try check.result([check.id: wrong], engine: engine, role: "target"))
                }
            }
        }
    }

    func testProgressRequiresExactCountersGTIDSetsAndOffsets() throws {
        for original in originals {
            let plan = try plan(original.id)
            XCTAssertEqual(plan.expectedDDL, 6)
            XCTAssertEqual(plan.expectedRows, 25)
            let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
            for cleaned in [false, true] {
                let n = cleaned ? 20 : 19
                let end = Boundary(file: "binlog.000003", position: 1000, gtids: "uuid:1-\(n+2)")
                let after: [String: Any] = [
                    "transactionsApplied": n + 2, "ddlApplied": cleaned ? 8 : 7, "rowsApplied": 28,
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

    func testFourTypesRemainNamedSelectionsOnOneSharedApplier() throws {
        let ids = originals.map { "matrix-" + $0.id }
        let selected = try LabScenario.select(tier: "full", family: nil, ids: Set(ids))
        XCTAssertEqual(Set(selected.map(\.id)), Set(ids))
        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(LabScenario.needsMainApplier(selected: Set(ids), slice: "all"))
        XCTAssertEqual(DMLCompatibilityCases.legacyFloatingAutoIncrement.map(\.id), originals.map(\.id))
        XCTAssertEqual(originals.map(\.type), ["FLOAT", "DOUBLE", "FLOAT(10,2)", "DOUBLE UNSIGNED"])
    }

    func testCleanupTitlesAndGlobalMembershipRemain() throws {
        for original in originals {
            let plan = try plan(original.id)
            XCTAssertEqual(plan.final.databases, ["poc"])
            XCTAssertEqual(plan.final.checks.count, 12)
            XCTAssertEqual(
                plan.cleanup.writes.map(\.sql),
                ["DROP TABLE " + original.histories.map { "poc." + $0 }.joined(separator: ",")])
            XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
            XCTAssertEqual(plan.cleanup.transactions, [1])
            XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
            XCTAssertEqual(
                try fixture(original.id).displayName,
                "Legacy AUTO_INCREMENT: " + original.type + " generated values, zero and key changes")
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "binarydefaults", "textdefaults", "zerowidth", "identifiercase",
                "unicodeidentifiers", "encodings", "widestrings",
                "spatial", "json", "typedjson", "jsonpartial", "floatbounds", "zerofill", "fixedfloating", "floating",
                "bits", "fixed",
                "enumzero", "choices",
                "widechoices",
                "integers", "decimal", "temporal", "precision", "lob", "defaults", "floatingautofloat",
                "floatingautodouble",
                "floatingautofixedfloat",
                "floatingautounsigneddouble",
            ])
    }
}
