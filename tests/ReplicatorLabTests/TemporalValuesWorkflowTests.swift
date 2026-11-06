import Foundation
import XCTest

@testable import ReplicatorLabCore

final class TemporalValuesWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "temporal",
            definition: "id INT PRIMARY KEY,d DATE,dt DATETIME(6),ts TIMESTAMP(6) NULL,t TIME(6),y YEAR",
            sql: [
                "SET SESSION time_zone='+05:30'; INSERT INTO poc.matrix_temporal VALUES(1,'2024-02-29','9999-12-31 23:59:59.999999','2024-02-29 05:30:00.123456','-838:59:59.000000',2155),(2,'0000-00-00','0000-00-00 00:00:00','0000-00-00 00:00:00','-00:00:00.000001',0)",
                "UPDATE poc.matrix_temporal SET ts='2038-01-19 03:14:07.999999',t='838:59:59.000000',d=NULL,y=1901 WHERE id=1",
                "DELETE FROM poc.matrix_temporal WHERE id=2",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2024-02-29 00:00:00.123456' AND t='-838:59:59.000000' AND y=2155",
                "SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2038-01-19 03:14:07.999999' AND d IS NULL AND y=1901",
                "SELECT COUNT(*)=1 FROM poc.matrix_temporal",
            ]),
        .init(
            id: "precision",
            definition:
                "id INT PRIMARY KEY,t0 TIME,t1 TIME(1),t2 TIME(2),t3 TIME(3),t4 TIME(4),t5 TIME(5),t6 TIME(6),d0 DATETIME,d3 DATETIME(3),s0 TIMESTAMP NULL,s3 TIMESTAMP(3) NULL",
            sql: [
                "INSERT INTO poc.matrix_precision VALUES(1,'-12:34:56','-00:00:00.1','-00:00:00.12','-00:00:00.123','-00:00:00.1234','-00:00:00.12345','-00:00:00.123456','2024-01-01 12:34:56','2024-01-01 12:34:56.789','1970-01-01 00:00:01','2024-01-01 12:34:56.789')",
                "UPDATE poc.matrix_precision SET t1='12:34:56.1',t6='00:00:00',d3=NULL WHERE id=1",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t6='-00:00:00.123456' AND d3='2024-01-01 12:34:56.789'",
                "SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t1='12:34:56.1' AND t6='00:00:00' AND d3 IS NULL",
            ]),
        .init(
            id: "defaults",
            definition:
                "id INT PRIMARY KEY AUTO_INCREMENT,v INT NOT NULL DEFAULT 7,s VARCHAR(40) DEFAULT 'seed',ts TIMESTAMP(6) NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)",
            sql: [
                "SET timestamp=1700000000.123456; INSERT INTO poc.matrix_defaults(s) VALUES(DEFAULT),('explicit')",
                "SET timestamp=1700000001.654321; UPDATE poc.matrix_defaults SET v=9 WHERE id=1",
                "INSERT INTO poc.matrix_defaults(id,v,s,ts) VALUES(0,0,'zero',NULL),(20,20,'explicit',NULL)",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(id)=3 AND SUM(v)=14 FROM poc.matrix_defaults",
                "SELECT COUNT(*)=1 FROM poc.matrix_defaults WHERE id=1 AND v=9 AND ts='2023-11-14 22:13:21.654321'",
                "SELECT COUNT(*)=4 AND MIN(id)=0 AND MAX(id)=20 FROM poc.matrix_defaults",
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
            (originals[0], ["tv_after_insert", "tv_after_update"], [1, 1, 1]),
            (originals[1], ["tp_after_insert"], [1, 1]),
            (originals[2], ["av_after_insert", "av_after_update"], [1, 1, 1]),
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

    func testSourceTimeZoneAndTimestampSettingsStayInsideOriginalRequests() throws {
        for id in ["temporal", "precision", "defaults"] {
            let plan = try plan(id)
            let session = LabProfile.forward.session
            let queries = try LabSQLPhase.queries(plan.body.writes, session: session, status: "SHOW BINARY LOG STATUS")
            for (index, write) in plan.body.writes.enumerated() {
                let sql = queries[index * 4].sql
                let reset = try XCTUnwrap(sql.range(of: "time_zone='+00:00'"))
                let body = try XCTUnwrap(sql.range(of: write.sql))
                XCTAssertLessThan(reset.lowerBound, body.lowerBound)
                XCTAssertTrue(sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                if id == "temporal" {
                    if write.sql.contains("INSERT INTO") {
                        let changed = try XCTUnwrap(sql.range(of: "time_zone='+05:30'"))
                        let insert = try XCTUnwrap(sql.range(of: "INSERT INTO"))
                        XCTAssertLessThan(reset.lowerBound, changed.lowerBound)
                        XCTAssertLessThan(changed.lowerBound, insert.lowerBound)
                    } else {
                        XCTAssertFalse(sql.contains("+05:30"))
                    }
                }
                if id == "defaults" {
                    if write.sql.contains("INSERT INTO") && !write.sql.contains("(id,v,s,ts)") {
                        XCTAssertTrue(write.sql.hasPrefix("USE poc; SET timestamp=1700000000.123456; INSERT INTO"))
                    } else if write.sql.contains("UPDATE") {
                        XCTAssertTrue(write.sql.hasPrefix("USE poc; SET timestamp=1700000001.654321; UPDATE"))
                    } else {
                        XCTAssertFalse(write.sql.contains("SET timestamp"))
                    }
                }
            }
            for query in plan.final.queries() {
                XCTAssertTrue(query.sql.contains("SET SESSION time_zone='+00:00'"))
            }
        }
    }

    func testCompleteTemporalRowsKeepUTCZeroDateRangesAndNull() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.tv_after_insert ORDER BY id",
                "1\t2024-02-29\t9999-12-31 23:59:59.999999\t2024-02-29 00:00:00.123456\t-838:59:59.000000\t2155\n2\t0000-00-00\t0000-00-00 00:00:00.000000\t0000-00-00 00:00:00.000000\t-00:00:00.000001\t0"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.tv_after_update ORDER BY id",
                "1\tNULL\t9999-12-31 23:59:59.999999\t2038-01-19 03:14:07.999999\t838:59:59.000000\t1901\n2\t0000-00-00\t0000-00-00 00:00:00.000000\t0000-00-00 00:00:00.000000\t-00:00:00.000001\t0"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.matrix_temporal ORDER BY id",
                "1\tNULL\t9999-12-31 23:59:59.999999\t2038-01-19 03:14:07.999999\t838:59:59.000000\t1901"
            ),
        ] {
            let check = try check("temporal", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("00:00:00.123456", "05:30:00.123456"), (".123456", ".123455"),
                    ("-00:00:00.000001", "00:00:00.000001"), ("-00:00:00.12345", "-00:00:00.1234"),
                    ("838:59:59", "838:59:58"), ("NULL", "0000-00-00"), (".654321", ".123456"),
                    ("73656564", "53656564"), ("0\t0\t", "3\t0\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testEveryFractionalSecondPrecisionAndUnchangedFieldRemains() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(CAST(t0 AS CHAR),'NULL'),IFNULL(CAST(t1 AS CHAR),'NULL'),IFNULL(CAST(t2 AS CHAR),'NULL'),IFNULL(CAST(t3 AS CHAR),'NULL'),IFNULL(CAST(t4 AS CHAR),'NULL'),IFNULL(CAST(t5 AS CHAR),'NULL'),IFNULL(CAST(t6 AS CHAR),'NULL'),IFNULL(CAST(d0 AS CHAR),'NULL'),IFNULL(CAST(d3 AS CHAR),'NULL'),IFNULL(CAST(s0 AS CHAR),'NULL'),IFNULL(CAST(s3 AS CHAR),'NULL') FROM poc.tp_after_insert ORDER BY id",
                "1\t-12:34:56\t-00:00:00.1\t-00:00:00.12\t-00:00:00.123\t-00:00:00.1234\t-00:00:00.12345\t-00:00:00.123456\t2024-01-01 12:34:56\t2024-01-01 12:34:56.789\t1970-01-01 00:00:01\t2024-01-01 12:34:56.789"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(CAST(t0 AS CHAR),'NULL'),IFNULL(CAST(t1 AS CHAR),'NULL'),IFNULL(CAST(t2 AS CHAR),'NULL'),IFNULL(CAST(t3 AS CHAR),'NULL'),IFNULL(CAST(t4 AS CHAR),'NULL'),IFNULL(CAST(t5 AS CHAR),'NULL'),IFNULL(CAST(t6 AS CHAR),'NULL'),IFNULL(CAST(d0 AS CHAR),'NULL'),IFNULL(CAST(d3 AS CHAR),'NULL'),IFNULL(CAST(s0 AS CHAR),'NULL'),IFNULL(CAST(s3 AS CHAR),'NULL') FROM poc.matrix_precision ORDER BY id",
                "1\t-12:34:56\t12:34:56.1\t-00:00:00.12\t-00:00:00.123\t-00:00:00.1234\t-00:00:00.12345\t00:00:00.000000\t2024-01-01 12:34:56\tNULL\t1970-01-01 00:00:01\t2024-01-01 12:34:56.789"
            ),
        ] {
            let check = try check("precision", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("00:00:00.123456", "05:30:00.123456"), (".123456", ".123455"),
                    ("-00:00:00.000001", "00:00:00.000001"), ("-00:00:00.12345", "-00:00:00.1234"),
                    ("838:59:59", "838:59:58"), ("NULL", "0000-00-00"), (".654321", ".123456"),
                    ("73656564", "53656564"), ("0\t0\t", "3\t0\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testAutomaticValuesKeepFixedClocksExplicitZeroAndNull() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.av_after_insert ORDER BY id",
                "1\t7\t73656564\t2023-11-14 22:13:20.123456\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.av_after_update ORDER BY id",
                "1\t9\t73656564\t2023-11-14 22:13:21.654321\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.matrix_defaults ORDER BY id",
                "0\t0\t7A65726F\tNULL\n1\t9\t73656564\t2023-11-14 22:13:21.654321\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456\n20\t20\t6578706C69636974\tNULL"
            ),
        ] {
            let check = try check("defaults", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n0"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("00:00:00.123456", "05:30:00.123456"), (".123456", ".123455"),
                    ("-00:00:00.000001", "00:00:00.000001"), ("-00:00:00.12345", "-00:00:00.1234"),
                    ("838:59:59", "838:59:58"), ("NULL", "0000-00-00"), (".654321", ".123456"),
                    ("73656564", "53656564"), ("0\t0\t", "3\t0\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testDeclaredPrecisionAutomaticAttributesAndStoredDefaultsRemain() throws {
        for (id, name, sql, value) in [
            (
                "temporal", "declared-fractional-seconds",
                "SELECT COLUMN_NAME,COLUMN_TYPE,DATETIME_PRECISION,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='tv_after_insert' AND COLUMN_NAME IN ('dt','ts','t') ORDER BY ORDINAL_POSITION",
                "dt\tdatetime(6)\t6\tYES\nts\ttimestamp(6)\t6\tYES\nt\ttime(6)\t6\tYES"
            ),
            (
                "precision", "declared-fractional-seconds",
                "SELECT COLUMN_NAME,COLUMN_TYPE,DATETIME_PRECISION,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='tp_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "t0\ttime\t0\tYES\nt1\ttime(1)\t1\tYES\nt2\ttime(2)\t2\tYES\nt3\ttime(3)\t3\tYES\nt4\ttime(4)\t4\tYES\nt5\ttime(5)\t5\tYES\nt6\ttime(6)\t6\tYES\nd0\tdatetime\t0\tYES\nd3\tdatetime(3)\t3\tYES\ns0\ttimestamp\t0\tYES\ns3\ttimestamp(3)\t3\tYES"
            ),
            (
                "defaults", "automatic-column-attributes",
                "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,EXTRA LIKE '%auto_increment%' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='av_after_update' ORDER BY ORDINAL_POSITION",
                "id\tint\tNO\t1\nv\tint\tNO\t0\ns\tvarchar\tYES\t0\nts\ttimestamp\tYES\t0"
            ),
            (
                "defaults", "automatic-timestamp-default-and-update",
                "SELECT DATETIME_PRECISION,LOWER(COLUMN_DEFAULT)='current_timestamp(6)',LOWER(EXTRA) LIKE '%on update current_timestamp(6)%' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='av_after_update' AND COLUMN_NAME='ts'",
                "6\t1\t1"
            ),
            (
                "defaults", "constant-stored-defaults",
                "SELECT DEFAULT(v),HEX(DEFAULT(s)) FROM poc.av_after_update WHERE id=1", "7\t73656564"
            ),
        ] {
            let check = try check(id, name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            for wrong in [
                value + "0", value.replacingOccurrences(of: "timestamp(6)", with: "timestamp(3)"),
                value.replacingOccurrences(of: "time(5)", with: "time(4)"),
                value.replacingOccurrences(of: "NO\t1", with: "NO\t0"),
                value.replacingOccurrences(of: "6\t1\t1", with: "6\t1\t0"),
            ] where value != wrong {
                XCTAssertThrowsError(try check.result([name: wrong], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testProgressRejectsWrongCountsGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [("temporal", 9, 3, 9), ("precision", 5, 2, 3), ("defaults", 9, 3, 10)] {
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
            let expected = ["temporal": 7, "precision": 5, "defaults": 9]
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
                "unicodeidentifiers", "encodings", "widestrings",
                "json", "typedjson", "floatbounds", "zerofill", "fixedfloating", "floating", "bits", "fixed",
                "enumzero", "choices",
                "widechoices",
                "integers", "decimal", "temporal", "precision", "lob", "defaults", "floatingautofloat",
                "floatingautodouble",
                "floatingautofixedfloat", "floatingautounsigneddouble",
            ])
    }
}
