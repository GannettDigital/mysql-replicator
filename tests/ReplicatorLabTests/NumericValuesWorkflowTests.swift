import Foundation
import XCTest

@testable import ReplicatorLabCore

final class NumericValuesWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "integers",
            definition:
                "id TINYINT PRIMARY KEY,a TINYINT,b TINYINT UNSIGNED,c SMALLINT,d SMALLINT UNSIGNED,e MEDIUMINT,f MEDIUMINT UNSIGNED",
            sql: [
                "INSERT INTO poc.matrix_integers VALUES(-128,-128,255,-32768,65535,-8388608,16777215),(127,127,0,32767,0,8388607,0)",
                "UPDATE poc.matrix_integers SET id=0,a=NULL,b=1,c=-1,d=1,e=-1,f=1 WHERE id=-128",
                "DELETE FROM poc.matrix_integers WHERE id=127",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND MIN(e)=-8388608 AND MAX(f)=16777215 FROM poc.matrix_integers",
                "SELECT COUNT(*)=1 FROM poc.matrix_integers WHERE id=0 AND a IS NULL AND e=-1",
                "SELECT COUNT(*)=1 FROM poc.matrix_integers",
            ]),
        .init(
            id: "decimal", definition: "id INT PRIMARY KEY,a DECIMAL(65,30),b DECIMAL(10,2) UNSIGNED,c DECIMAL(4,4)",
            sql: [
                "INSERT INTO poc.matrix_decimal VALUES(1,-12345678901234567890123456789012345.123456789012345678901234567890,99999999.99,-0.9999),(2,0,0,0)",
                "UPDATE poc.matrix_decimal SET a=99999999999999999999999999999999999.999999999999999999999999999999,b=NULL,c=0.0001 WHERE id=1",
                "DELETE FROM poc.matrix_decimal WHERE id=2",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=-12345678901234567890123456789012345.123456789012345678901234567890 AND b=99999999.99 AND c=-0.9999",
                "SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=99999999999999999999999999999999999.999999999999999999999999999999 AND b IS NULL AND c=0.0001",
                "SELECT COUNT(*)=1 FROM poc.matrix_decimal",
            ]),
        .init(
            id: "bits", definition: "id BIT(64) PRIMARY KEY,a BIT DEFAULT b'1',b BIT(7),c BIT(8),d BIT(9),e BIT(63)",
            sql: [
                "INSERT INTO poc.matrix_bits VALUES(0,0,0,0,0,0),(18446744073709551615,1,127,255,511,9223372036854775807),(9223372036854775808,NULL,NULL,NULL,NULL,NULL)",
                "UPDATE poc.matrix_bits SET id=72623859790382856,a=DEFAULT,b=64,c=128,d=256,e=4611686018427387904 WHERE id=0",
                "ALTER TABLE poc.matrix_bits MODIFY d BIT(16) DEFAULT b'100000000', ADD f BIT(8) DEFAULT b'11111111'; UPDATE poc.matrix_bits SET d=65535 WHERE id=18446744073709551615",
                "DELETE FROM poc.matrix_bits WHERE id IN (72623859790382856,18446744073709551615)",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE CAST(id AS UNSIGNED)=18446744073709551615 AND a+0=1 AND b+0=127 AND c+0=255 AND d+0=511 AND e+0=9223372036854775807",
                "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=72623859790382856 AND a+0=1 AND b+0=64 AND c+0=128 AND d+0=256 AND e+0=4611686018427387904",
                "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=18446744073709551615 AND d+0=65535 AND f+0=255",
                "SELECT COUNT(*)=1 FROM poc.matrix_bits WHERE id=9223372036854775808 AND a IS NULL AND e IS NULL",
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
            XCTAssertFalse(test.phases.contains(where: \.expectsJSONDiff))
        }
    }

    func testColdMetadataKeepsEachDefinitionAndFirstInsertOnEveryProfile() throws {
        for original in originals {
            XCTAssertEqual(MetadataDiscoveryCases.owner(original.id), MetadataDiscoveryCases.columns.id)
            XCTAssertEqual(MetadataDiscoveryCases.representative(original.id), original.id)
            for profile in LabProfile.allCases {
                XCTAssertTrue(try fixture(original.id).applies(to: profile))
                let cold = try XCTUnwrap(
                    MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                        $0.id == original.id
                    })
                XCTAssertEqual(Data(cold.definition.utf8), Data(original.definition.utf8))
                XCTAssertEqual(cold.phases[0].sql, original.sql[0])
                XCTAssertEqual(cold.phases[0].check, original.predicates[0])
                XCTAssertNil(cold.rowMetadata)
            }
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
        [
            (originals[0], ["iv_after_insert", "iv_after_update"], [1, 1, 1]),
            (originals[1], ["dv_after_insert", "dv_after_update"], [1, 1, 1]),
            (originals[2], ["bv_after_insert", "bv_after_update", "bv_after_widen"], [1, 1, 2, 1]),
        ]
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

    func testIntegerExtremaKeyChangeNullAndUnaffectedRow() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.iv_after_insert ORDER BY id",
                "-128\t-128\t255\t-32768\t65535\t-8388608\t16777215\n127\t127\t0\t32767\t0\t8388607\t0"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.iv_after_update ORDER BY id",
                "0\tNULL\t1\t-1\t1\t-1\t1\n127\t127\t0\t32767\t0\t8388607\t0"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.matrix_integers ORDER BY id",
                "0\tNULL\t1\t-1\t1\t-1\t1"
            ),
        ] {
            let check = try check("integers", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("-128", "128"), ("16777215", "16777214"), ("65535", "-1"), ("NULL", "0"), ("127\t127", "126\t127"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testDecimalPrecisionScaleAndLastDigitRemainExact() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.dv_after_insert ORDER BY id",
                "1\t-12345678901234567890123456789012345.123456789012345678901234567890\t99999999.99\t-0.9999\n2\t0.000000000000000000000000000000\t0.00\t0.0000"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.dv_after_update ORDER BY id",
                "1\t99999999999999999999999999999999999.999999999999999999999999999999\tNULL\t0.0001\n2\t0.000000000000000000000000000000\t0.00\t0.0000"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.matrix_decimal ORDER BY id",
                "1\t99999999999999999999999999999999999.999999999999999999999999999999\tNULL\t0.0001"
            ),
        ] {
            let check = try check("decimal", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("123456789012345678901234567890", "123456789012345678901234567891"),
                    ("999999999999999999999999999999", "999999999999999999999999999998"),
                    ("99999999.99", "99999999.98"), ("NULL", "0.00"), ("0.0001", "0.0000"),
                    ("0.000000000000000000000000000000", "0"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testBitUnsignedHighBitsNullAndKeyChangeRemainExact() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL') FROM poc.bv_after_insert ORDER BY id",
                "0\t0\t0\t0\t0\t0\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\n18446744073709551615\t1\t127\t255\t511\t9223372036854775807"
            ),
            (
                "updated-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL') FROM poc.bv_after_update ORDER BY id",
                "72623859790382856\t1\t64\t128\t256\t4611686018427387904\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\n18446744073709551615\t1\t127\t255\t511\t9223372036854775807"
            ),
            (
                "widened-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL') FROM poc.bv_after_widen ORDER BY id",
                "72623859790382856\t1\t64\t128\t256\t4611686018427387904\t255\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\t255\n18446744073709551615\t1\t127\t255\t65535\t9223372036854775807\t255"
            ),
            (
                "final-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL') FROM poc.matrix_bits ORDER BY id",
                "9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\t255"
            ),
        ] {
            let check = try check("bits", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("18446744073709551615", "-1"), ("9223372036854775808", "-9223372036854775808"),
                    ("72623859790382856", "578437695752307201"), ("65535", "511"), ("NULL", "0"),
                    ("4611686018427387904", "4611686018427387903"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testBitWidthsNullabilityAndStoredDefaultsRemainSeparateFromRows() throws {
        for (name, sql, value) in [
            (
                "initial-bit-declarations",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bv_after_insert' ORDER BY ORDINAL_POSITION",
                "id\tbit(64)\tNO\t1\na\tbit(1)\tYES\t0\nb\tbit(7)\tYES\t1\nc\tbit(8)\tYES\t1\nd\tbit(9)\tYES\t1\ne\tbit(63)\tYES\t1"
            ),
            ("initial-bit-defaults", "SELECT CAST(DEFAULT(a) AS UNSIGNED) FROM poc.bv_after_insert WHERE id=0", "1"),
            (
                "widened-bit-declarations",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bv_after_widen' ORDER BY ORDINAL_POSITION",
                "id\tbit(64)\tNO\t1\na\tbit(1)\tYES\t0\nb\tbit(7)\tYES\t1\nc\tbit(8)\tYES\t1\nd\tbit(16)\tYES\t0\ne\tbit(63)\tYES\t1\nf\tbit(8)\tYES\t0"
            ),
            (
                "widened-bit-defaults",
                "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(d) AS UNSIGNED),CAST(DEFAULT(f) AS UNSIGNED) FROM poc.bv_after_widen WHERE id=72623859790382856",
                "1\t256\t255"
            ),
        ] {
            let check = try check("bits", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([name: value + "0"], engine: "MyISAM", role: "target"))
            for (old, wrong) in [
                ("bit(64)", "bit(63)"), ("bit(9)", "bit(8)"), ("bit(16)", "bit(9)"), ("YES", "NO"), ("256", "255"),
            ] where value.contains(old) {
                XCTAssertThrowsError(
                    try check.result(
                        [name: value.replacingOccurrences(of: old, with: wrong)], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testProgressRejectsIncorrectCountersGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [("integers", 9, 3, 9), ("decimal", 9, 3, 9), ("bits", 16, 6, 19)] {
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
                    wrong[key] = (after[key] as! Int) - 1
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

    func testCleanupTitlesAndGlobalMembershipKeepExistingSelections() throws {
        for (original, histories, _) in zipOriginals() {
            let plan = try plan(original.id)
            XCTAssertEqual(plan.final.databases, ["poc"])
            XCTAssertEqual(
                plan.cleanup.writes.map(\.sql), ["DROP TABLE " + histories.map { "poc." + $0 }.joined(separator: ",")])
            XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
            XCTAssertEqual(plan.cleanup.transactions, [1])
            XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
            XCTAssertEqual(plan.final.checks.count, original.id == "bits" ? 12 : 6)
            XCTAssertEqual(
                LabScenario.correctness.first { $0.id == "matrix-" + original.id }?.test.name,
                try fixture(original.id).displayName)
        }
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
