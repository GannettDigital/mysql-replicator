import Foundation
import XCTest

@testable import ReplicatorLabCore

final class FloatingValuesWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "floatbounds", definition: "id FLOAT(8,2) PRIMARY KEY,v FLOAT(8,2),u FLOAT(8,2) UNSIGNED",
            sql: [
                "INSERT INTO poc.matrix_floatbounds VALUES(999999.99,999999.99,999999.99),(-999999.99,-999999.99,0)",
                "UPDATE poc.matrix_floatbounds SET id=1,v=-999999.99,u=999999.99 WHERE id>0",
                "DELETE FROM poc.matrix_floatbounds WHERE id<0",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(id)=0 AND SUM(v)=0 AND SUM(u)=1000000 FROM poc.matrix_floatbounds",
                "SELECT COUNT(*)=1 FROM poc.matrix_floatbounds WHERE id=1 AND v+0e0=-1000000e0 AND u+0e0=1000000e0",
                "SELECT COUNT(*)=1 AND MIN(id)=1 FROM poc.matrix_floatbounds",
            ]),
        .init(
            id: "zerofill",
            definition:
                "id INT ZEROFILL PRIMARY KEY,a TINYINT(6) ZEROFILL DEFAULT 7,b DECIMAL(8,2) ZEROFILL DEFAULT 1.25,c FLOAT ZEROFILL DEFAULT 1.25,d DOUBLE(10,2) ZEROFILL DEFAULT 1.235,e INT(0) ZEROFILL,f BIGINT ZEROFILL,y YEAR ZEROFILL",
            sql: [
                "INSERT INTO poc.matrix_zerofill(id) VALUES(0),(1),(2)",
                "UPDATE poc.matrix_zerofill SET id=4294967295,a=255,b=999999.99,c=0.125,d=9.875,e=4294967295,f=18446744073709551615,y=2155 WHERE id=0",
                "ALTER TABLE poc.matrix_zerofill MODIFY a TINYINT(8) ZEROFILL DEFAULT 9, ADD g MEDIUMINT ZEROFILL DEFAULT 42; UPDATE poc.matrix_zerofill SET a=DEFAULT,g=16777215 WHERE id=1",
                "DELETE FROM poc.matrix_zerofill WHERE id IN (1,4294967295)",
            ],
            predicates: [
                "SELECT COUNT(*)=3 AND SUM(a)=21 AND SUM(b)=3.75 FROM poc.matrix_zerofill",
                "SELECT COUNT(*)=1 FROM poc.matrix_zerofill WHERE id=4294967295 AND a=255 AND b=999999.99 AND d=9.88 AND f=18446744073709551615 AND y=2155",
                "SELECT COUNT(*)=1 FROM poc.matrix_zerofill WHERE id=1 AND a=9 AND g=16777215",
                "SELECT COUNT(*)=1 AND MIN(id)=2 FROM poc.matrix_zerofill",
            ]),
        .init(
            id: "fixedfloating",
            definition:
                "id DOUBLE(10,2) PRIMARY KEY,a FLOAT(10,2) DEFAULT 1.235,b DOUBLE(20,6) DEFAULT -1.23456789,c FLOAT(30,20) DEFAULT 0.1,d DOUBLE(200,0) DEFAULT 1e199,u FLOAT(10,2) UNSIGNED",
            sql: [
                "INSERT INTO poc.matrix_fixedfloating(id,u) VALUES(1,0),(2,1.235),(3,NULL); INSERT INTO poc.matrix_fixedfloating VALUES(4,NULL,NULL,NULL,NULL,NULL)",
                "UPDATE poc.matrix_fixedfloating SET id=10.255,a=-99999.125,b=0.0000001,c=-0.00001,d=-1e199,u=9999.999 WHERE id=1",
                "ALTER TABLE poc.matrix_fixedfloating ADD e DOUBLE(10,2) DEFAULT 9.875, MODIFY a FLOAT(12,3) DEFAULT -1.2345; UPDATE poc.matrix_fixedfloating SET a=DEFAULT,e=DEFAULT WHERE id=2",
                "DELETE FROM poc.matrix_fixedfloating WHERE id IN (2,3,10.26)",
            ],
            predicates: [
                "SELECT COUNT(*)=4 AND SUM(a IS NULL)=1 AND SUM(b=-1.234568)=3 FROM poc.matrix_fixedfloating",
                "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=10.26 AND a<0 AND b=0 AND c<0 AND d=-1e199 AND u=10000",
                "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=2 AND a< -1.23 AND a> -1.24 AND e=9.88",
                "SELECT COUNT(*)=1 FROM poc.matrix_fixedfloating WHERE id=4 AND a IS NULL AND b IS NULL",
            ]),
        .init(
            id: "floating", definition: "id DOUBLE PRIMARY KEY,a FLOAT,b DOUBLE,c FLOAT UNSIGNED DEFAULT 1.23456789",
            sql: [
                "INSERT INTO poc.matrix_floating VALUES(0,0,0,0),(1,0.1,0.1,0.125),(2,-0.1,-0.1,NULL),(3,1.1754943508222875e-38,2.2250738585072014e-308,1),(4,NULL,NULL,NULL)",
                "UPDATE poc.matrix_floating SET id=10.25,a=1.401298464324817e-45,b=4.9406564584124654e-324,c=DEFAULT WHERE id=1",
                "UPDATE poc.matrix_floating SET a=3.4028234663852886e38,b=1.7976931348623157e308 WHERE id=2",
                "ALTER TABLE poc.matrix_floating ADD d DOUBLE PRECISION DEFAULT 1.25e-2, MODIFY c FLOAT(25) UNSIGNED DEFAULT 0.125; UPDATE poc.matrix_floating SET c=0.1,d=-1.25e12 WHERE id=3",
                "DELETE FROM poc.matrix_floating WHERE id IN (0,2,3,10.25)",
            ],
            predicates: [
                "SELECT COUNT(*)=5 AND SUM(a IS NULL)=1 AND SUM(c IS NULL)=2 FROM poc.matrix_floating",
                "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=10.25 AND a>0 AND a<1e-40 AND b>0 AND b<1e-310 AND c>1.23456 AND c<1.23458",
                "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=2 AND a>3.40282e38 AND b>1.79769e308",
                "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=3 AND c=0.1 AND d=-1.25e12",
                "SELECT COUNT(*)=1 FROM poc.matrix_floating WHERE id=4 AND a IS NULL AND b IS NULL",
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
            (originals[0], ["fb_after_insert", "fb_after_update"], [1, 1, 1]),
            (originals[1], ["zf_after_insert", "zf_after_update", "zf_after_alter"], [1, 1, 2, 1]),
            (originals[2], ["ff_after_insert", "ff_after_update", "ff_after_alter"], [2, 1, 2, 1]),
            (
                originals[3], ["fl_after_insert", "fl_after_key_update", "fl_after_max_update", "fl_after_alter"],
                [1, 1, 1, 2, 1]
            ),
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

    func testFloatBoundaryRoundingKeyChangeAndDeletedRow() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.fb_after_insert ORDER BY id",
                "-1000000.00\t-1000000.00\t0.00\n1000000.00\t1000000.00\t1000000.00"
            ),
            (
                "updated-rows",
                "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.fb_after_update ORDER BY id",
                "-1000000.00\t-1000000.00\t0.00\n1.00\t-1000000.00\t1000000.00"
            ),
            (
                "final-rows",
                "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.matrix_floatbounds ORDER BY id",
                "1.00\t-1000000.00\t1000000.00"
            ),
        ] {
            let check = try check("floatbounds", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("NULL", "0"), ("1000000.00", "999999.99"), ("18446744073709551615", "-1"), ("4294967295", "-1"),
                    ("10.26", "10.25"), ("10.25", "1.00"), ("\t1", "\t0"),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testZerofillCompleteNumericRowsUnsignedLimitsAndNull() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.zf_after_insert ORDER BY id",
                "0\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n1\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL"
            ),
            (
                "updated-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.zf_after_update ORDER BY id",
                "1\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n4294967295\t255\t999999.99\t0.125\t9.88\t4294967295\t18446744073709551615\t2155"
            ),
            (
                "altered-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL'),IFNULL(CAST(g AS UNSIGNED),'NULL') FROM poc.zf_after_alter ORDER BY id",
                "1\t9\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t16777215\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t42\n4294967295\t255\t999999.99\t0.125\t9.88\t4294967295\t18446744073709551615\t2155\t42"
            ),
            (
                "final-rows",
                "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL'),IFNULL(CAST(g AS UNSIGNED),'NULL') FROM poc.matrix_zerofill ORDER BY id",
                "2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t42"
            ),
        ] {
            let check = try check("zerofill", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("NULL", "0"), ("1000000.00", "999999.99"), ("18446744073709551615", "-1"), ("4294967295", "-1"),
                    ("10.26", "10.25"), ("10.25", "1.00"), ("\t1", "\t0"),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testFixedScaleFloatDoubleRoundingAndNullRows() throws {
        for (name, sql, value) in [
            (
                "initial-field-values",
                "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a>1.2399 AND a<1.2401 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL') FROM poc.ff_after_insert ORDER BY id",
                "1.00\t1\t1\t1\t1\t1\n2.00\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL"
            ),
            (
                "updated-field-values",
                "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a>1.2399 AND a<1.2401 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL') FROM poc.ff_after_update ORDER BY id",
                "2.00\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL\n10.26\t1\t1\t1\t1\t1"
            ),
            (
                "altered-field-values",
                "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a> -1.236 AND a< -1.233 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL'),IFNULL((e=9.88),'NULL') FROM poc.ff_after_alter ORDER BY id",
                "2.00\t1\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\t1\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL\t1\n10.26\t1\t1\t1\t1\t1\t1"
            ),
            (
                "final-null-row",
                "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a> -1.236 AND a< -1.233 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL'),IFNULL((e=9.88),'NULL') FROM poc.matrix_fixedfloating ORDER BY id",
                "4.00\tNULL\tNULL\tNULL\tNULL\tNULL\t1"
            ),
        ] {
            let check = try check("fixedfloating", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("NULL", "0"), ("1000000.00", "999999.99"), ("18446744073709551615", "-1"), ("4294967295", "-1"),
                    ("10.26", "10.25"), ("10.25", "1.00"), ("\t1", "\t0"),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testFloatDoubleNormalSubnormalMaximumAndNullRows() throws {
        for (name, sql, value) in [
            (
                "initial-field-values",
                "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a> -0.10000001 AND a< -0.09999999 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=-1e-1 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_insert ORDER BY id",
                "0.00\t1\t1\t1\n1.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL"
            ),
            (
                "subnormal-field-values",
                "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a> -0.10000001 AND a< -0.09999999 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=-1e-1 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_key_update ORDER BY id",
                "0.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\n10.25\t1\t1\t1"
            ),
            (
                "maximum-field-values",
                "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_max_update ORDER BY id",
                "0.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\n10.25\t1\t1\t1"
            ),
            (
                "altered-field-values",
                "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1e-1 END),'NULL'),IFNULL((CASE WHEN id=3 THEN d=-1.25e12 ELSE d=1.25e-2 END),'NULL') FROM poc.fl_after_alter ORDER BY id",
                "0.00\t1\t1\t1\t1\n2.00\t1\t1\tNULL\t1\n3.00\t1\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\t1\n10.25\t1\t1\t1\t1"
            ),
            (
                "final-null-row",
                "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1e-1 END),'NULL'),IFNULL((CASE WHEN id=3 THEN d=-1.25e12 ELSE d=1.25e-2 END),'NULL') FROM poc.matrix_floating ORDER BY id",
                "4.00\tNULL\tNULL\tNULL\t1"
            ),
        ] {
            let check = try check("floating", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("NULL", "0"), ("1000000.00", "999999.99"), ("18446744073709551615", "-1"), ("4294967295", "-1"),
                    ("10.26", "10.25"), ("10.25", "1.00"), ("\t1", "\t0"),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testDeclaredTypesNumericAttributesAndDefaultsStayIndependentFromRows() throws {
        for (id, name, sql, value) in [
            (
                "zerofill", "initial-unsigned-zerofill-attributes",
                "SELECT COLUMN_NAME,DATA_TYPE,LOCATE('unsigned',COLUMN_TYPE)>0,LOCATE('zerofill',COLUMN_TYPE)>0,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zf_after_insert' AND COLUMN_NAME<>'y' ORDER BY ORDINAL_POSITION",
                "id\tint\t1\t1\tNO\na\ttinyint\t1\t1\tYES\nb\tdecimal\t1\t1\tYES\nc\tfloat\t1\t1\tYES\nd\tdouble\t1\t1\tYES\ne\tint\t1\t1\tYES\nf\tbigint\t1\t1\tYES"
            ),
            (
                "zerofill", "initial-stored-defaults",
                "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(b) AS DECIMAL(8,2)),CAST(DEFAULT(c) AS DECIMAL(8,3)),CAST(DEFAULT(d) AS DECIMAL(10,2)) FROM poc.zf_after_insert WHERE id=1",
                "7\t1.25\t1.250\t1.24"
            ),
            (
                "zerofill", "altered-unsigned-zerofill-attributes",
                "SELECT COLUMN_NAME,DATA_TYPE,LOCATE('unsigned',COLUMN_TYPE)>0,LOCATE('zerofill',COLUMN_TYPE)>0,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zf_after_alter' AND COLUMN_NAME<>'y' ORDER BY ORDINAL_POSITION",
                "id\tint\t1\t1\tNO\na\ttinyint\t1\t1\tYES\nb\tdecimal\t1\t1\tYES\nc\tfloat\t1\t1\tYES\nd\tdouble\t1\t1\tYES\ne\tint\t1\t1\tYES\nf\tbigint\t1\t1\tYES\ng\tmediumint\t1\t1\tYES"
            ),
            (
                "zerofill", "altered-stored-defaults",
                "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(b) AS DECIMAL(8,2)),CAST(DEFAULT(c) AS DECIMAL(8,3)),CAST(DEFAULT(d) AS DECIMAL(10,2)),CAST(DEFAULT(g) AS UNSIGNED) FROM poc.zf_after_alter WHERE id=1",
                "9\t1.25\t1.250\t1.24\t42"
            ),
            (
                "fixedfloating", "initial-stored-defaults",
                "SELECT (DEFAULT(a)>1.2399 AND DEFAULT(a)<1.2401),(DEFAULT(b)=-1.234568),(DEFAULT(c)>0.09999999 AND DEFAULT(c)<0.10000001),(DEFAULT(d)=1e199) FROM poc.ff_after_insert WHERE id=2",
                "1\t1\t1\t1"
            ),
            (
                "fixedfloating", "initial-declared-types",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ff_after_insert' ORDER BY ORDINAL_POSITION",
                "id\tdouble(10,2)\tNO\na\tfloat(10,2)\tYES\nb\tdouble(20,6)\tYES\nc\tfloat(30,20)\tYES\nd\tdouble(200,0)\tYES\nu\tfloat(10,2) unsigned\tYES"
            ),
            (
                "fixedfloating", "altered-stored-defaults",
                "SELECT (DEFAULT(a)> -1.236 AND DEFAULT(a)< -1.233),(DEFAULT(b)=-1.234568),(DEFAULT(c)>0.09999999 AND DEFAULT(c)<0.10000001),(DEFAULT(d)=1e199),(DEFAULT(e)=9.88) FROM poc.ff_after_alter WHERE id=2",
                "1\t1\t1\t1\t1"
            ),
            (
                "fixedfloating", "altered-declared-types",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ff_after_alter' ORDER BY ORDINAL_POSITION",
                "id\tdouble(10,2)\tNO\na\tfloat(12,3)\tYES\nb\tdouble(20,6)\tYES\nc\tfloat(30,20)\tYES\nd\tdouble(200,0)\tYES\nu\tfloat(10,2) unsigned\tYES\ne\tdouble(10,2)\tYES"
            ),
            (
                "floating", "initial-stored-defaults",
                "SELECT (DEFAULT(c)>1.23456 AND DEFAULT(c)<1.23458) FROM poc.fl_after_insert WHERE id=4", "1"
            ),
            (
                "floating", "initial-declared-types",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fl_after_insert' ORDER BY ORDINAL_POSITION",
                "id\tdouble\tNO\na\tfloat\tYES\nb\tdouble\tYES\nc\tfloat unsigned\tYES"
            ),
            (
                "floating", "altered-stored-defaults",
                "SELECT (DEFAULT(c)=0.125),(DEFAULT(d)=1.25e-2) FROM poc.fl_after_alter WHERE id=4", "1\t1"
            ),
            (
                "floating", "altered-declared-types",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fl_after_alter' ORDER BY ORDINAL_POSITION",
                "id\tdouble\tNO\na\tfloat\tYES\nb\tdouble\tYES\nc\tdouble unsigned\tYES\nd\tdouble\tYES"
            ),
        ] {
            let check = try check(id, name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            for wrong in [
                value + "0", value.replacingOccurrences(of: "float(12,3)", with: "float(10,2)"),
                value.replacingOccurrences(of: "double unsigned", with: "float unsigned"),
                value.replacingOccurrences(of: "1\t1", with: "1\t0"),
            ] where wrong != value {
                XCTAssertThrowsError(try check.result([name: wrong], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testProgressRejectsWrongCountsGTIDsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("floatbounds", 9, 3, 9), ("zerofill", 16, 6, 19), ("fixedfloating", 20, 6, 24), ("floating", 22, 7, 38),
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

    func testCleanupSharedTitlesAndMembershipKeepSelections() throws {
        for (original, histories, _) in zipOriginals() {
            let plan = try plan(original.id)
            XCTAssertEqual(plan.final.databases, ["poc"])
            XCTAssertEqual(
                plan.cleanup.writes.map(\.sql), ["DROP TABLE " + histories.map { "poc." + $0 }.joined(separator: ",")])
            XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
            XCTAssertEqual(plan.cleanup.transactions, [1])
            XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
            let expected = ["floatbounds": 6, "zerofill": 12, "fixedfloating": 12, "floating": 14]
            XCTAssertEqual(plan.final.checks.count, expected[original.id])
            XCTAssertEqual(
                LabScenario.correctness.first { $0.id == "matrix-" + original.id }?.test.name,
                try fixture(original.id).displayName)
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "zerowidth", "identifiercase", "unicodeidentifiers", "encodings", "widestrings",
                "floatbounds", "zerofill", "fixedfloating", "floating", "bits", "enumzero", "choices", "widechoices",
                "integers", "decimal",
            ])
    }
}
