import Foundation
import XCTest

@testable import ReplicatorLabCore

final class CharacterBinaryWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "encodings",
            definition:
                "id VARCHAR(12) CHARACTER SET latin1 COLLATE latin1_swedish_ci PRIMARY KEY,c CHAR(4) CHARACTER SET latin1 COLLATE latin1_bin,v VARCHAR(20) CHARACTER SET latin1 COLLATE latin1_bin,t TEXT CHARACTER SET latin1 COLLATE latin1_bin,a VARCHAR(20) CHARACTER SET ascii COLLATE ascii_general_ci,u VARCHAR(20) CHARACTER SET utf8 COLLATE utf8_bin DEFAULT '中',b CHAR(4) CHARACTER SET binary,doc JSON",
            sql: [
                "INSERT INTO poc.matrix_encodings VALUES(CONVERT(0xE9 USING latin1),CONVERT(0xE92020 USING latin1),CONVERT(0x0080FF20 USING latin1),CONVERT(0xE980FF00 USING latin1),CONVERT(0x410020 USING ascii),DEFAULT,0xFF20,JSON_OBJECT('n',CAST('1.25' AS DECIMAL(3,2)))),('second',NULL,'',NULL,'','',NULL,NULL)",
                "UPDATE poc.matrix_encodings SET id=CONVERT(0xC958 USING latin1),v=CONVERT(0xFF00E9 USING latin1),a='Next',u=CONVERT(0xC3A9 USING utf8),doc=JSON_OBJECT('n',CAST('2.50' AS DECIMAL(3,2))) WHERE id=CONVERT(0xC9 USING latin1)",
                "ALTER TABLE poc.matrix_encodings ADD extra CHAR(3) CHARACTER SET ascii DEFAULT 'x'; UPDATE poc.matrix_encodings SET extra='Z  ',t=CONVERT(0xE900FF USING latin1) WHERE id=CONVERT(0xE958 USING latin1)",
                "DELETE FROM poc.matrix_encodings WHERE id=CONVERT(0xE978 USING latin1)",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xC9 USING latin1) AND HEX(c)='E9' AND HEX(v)='0080FF20' AND HEX(t)='E980FF00' AND HEX(a)='410020' AND HEX(u)='E4B8AD' AND HEX(b)='FF200000' AND JSON_TYPE(JSON_EXTRACT(doc,'$.n'))='DECIMAL'",
                "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xE978 USING latin1) AND HEX(id)='C958' AND HEX(v)='FF00E9' AND a='next' AND HEX(u)='C3A9' AND JSON_TYPE(JSON_EXTRACT(doc,'$.n'))='DECIMAL'",
                "SELECT COUNT(*)=1 FROM poc.matrix_encodings WHERE id=CONVERT(0xC958 USING latin1) AND HEX(extra)='5A' AND HEX(t)='E900FF'",
                "SELECT COUNT(*)=1 AND SUM(id='second')=1 AND SUM(c IS NULL)=1 FROM poc.matrix_encodings",
            ]),
        .init(
            id: "widestrings",
            definition:
                "id INT PRIMARY KEY,v VARCHAR(20000) CHARACTER SET latin1 COLLATE latin1_bin,b VARBINARY(20000)",
            sql: [
                "INSERT INTO poc.matrix_widestrings VALUES(1,REPEAT(CONVERT(0xE9 USING latin1),18000),REPEAT(0xFF00,9000))",
                "UPDATE poc.matrix_widestrings SET v=CONVERT(0x00FF USING latin1),b=0xFF WHERE id=1",
                "DELETE FROM poc.matrix_widestrings WHERE id=1",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_widestrings WHERE OCTET_LENGTH(v)=18000 AND OCTET_LENGTH(b)=18000 AND HEX(RIGHT(v,1))='E9' AND HEX(RIGHT(b,2))='FF00'",
                "SELECT COUNT(*)=1 FROM poc.matrix_widestrings WHERE HEX(v)='00FF' AND HEX(b)='FF'",
                "SELECT COUNT(*)=0 FROM poc.matrix_widestrings",
            ]),
        .init(
            id: "zerowidth",
            definition:
                "id INT PRIMARY KEY,c CHAR(0) DEFAULT '',v VARCHAR(0) DEFAULT '',b BINARY(0) DEFAULT X'',w VARBINARY(0) DEFAULT X'',u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''",
            sql: [
                "INSERT INTO poc.matrix_zerowidth VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT),(2,NULL,NULL,NULL,NULL,NULL)",
                "UPDATE poc.matrix_zerowidth SET c=NULL,v=NULL,b=NULL,w=NULL,u=NULL WHERE id=1; UPDATE poc.matrix_zerowidth SET c='',v='',b=X'',w=X'',u='' WHERE id=2",
                "ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(4) DEFAULT 'x',MODIFY w VARBINARY(4) DEFAULT X'ff',MODIFY u VARCHAR(4) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X'4e2d'; UPDATE poc.matrix_zerowidth SET v='hi',w=X'ff00',u='中' WHERE id=1",
                "UPDATE poc.matrix_zerowidth SET v='',w=X'',u='' WHERE id=1; ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(0) DEFAULT '',MODIFY w VARBINARY(0) DEFAULT X'',MODIFY u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''; DELETE FROM poc.matrix_zerowidth WHERE id=2",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 AND SUM(id=2 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 FROM poc.matrix_zerowidth",
                "SELECT COUNT(*)=2 AND SUM(id=1 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 AND SUM(id=2 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth",
                "SELECT COUNT(*)=1 FROM poc.matrix_zerowidth WHERE id=1 AND v='hi' AND HEX(w)='FF00' AND HEX(u)='4E2D'",
                "SELECT COUNT(*)=1 AND SUM(id=1 AND c IS NULL AND b IS NULL AND HEX(v)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth",
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

    func testOriginalDefinitionsScriptsAndPredicatesRemain() throws {
        for original in originals {
            let test = try fixture(original.id)
            XCTAssertEqual(Data(test.definition.utf8), Data(original.definition.utf8))
            XCTAssertEqual(test.phases.map { Data($0.sql.utf8) }, original.sql.map { Data($0.utf8) })
            XCTAssertEqual(test.phases.map(\.check), original.predicates)
            XCTAssertTrue(test.setup.isEmpty)
            XCTAssertEqual(test.orderBy, "id")
            XCTAssertNil(test.rowMetadata)
            XCTAssertNil(test.replicatedReplacement)
            XCTAssertFalse(test.phases.contains(where: \.expectsJSONDiff))
            XCTAssertTrue(test.profileExclusions.isEmpty)
        }
    }

    func testColdMetadataKeepsEachOriginalDefinitionAndFirstInsert() throws {
        for original in originals {
            let owner =
                original.id == "widestrings" ? MetadataDiscoveryCases.columns.id : MetadataDiscoveryCases.encodings.id
            XCTAssertEqual(MetadataDiscoveryCases.owner(original.id), owner)
            XCTAssertEqual(MetadataDiscoveryCases.representative(original.id), original.id)
            for profile in LabProfile.allCases {
                XCTAssertTrue(try fixture(original.id).applies(to: profile))
                let cold = try XCTUnwrap(
                    MetadataDiscoveryCases.fixtures(owner, profile: profile).first { $0.id == original.id })
                XCTAssertEqual(Data(cold.definition.utf8), Data(original.definition.utf8))
                XCTAssertEqual(cold.phases[0].sql, original.sql[0])
                XCTAssertEqual(cold.phases[0].check, original.predicates[0])
                XCTAssertNil(cold.rowMetadata)
            }
        }
    }

    func testBatchesKeepOriginalOrderAndEachCompoundRequest() throws {
        let sourceCounts = ["encodings": [1, 1, 2, 1], "widestrings": [1, 1, 1], "zerowidth": [1, 2, 2, 3]]
        for (original, tables) in zip(
            originals,
            [
                ["ev_after_insert", "ev_after_update", "ev_after_add"],
                ["ws_after_insert", "ws_after_update"],
                ["zw_after_insert", "zw_after_update", "zw_after_widen"],
            ])
        {
            let counts = try XCTUnwrap(sourceCounts[original.id])
            let plan = try plan(original.id)
            XCTAssertEqual(
                plan.prepare.writes.map(\.sql),
                (["matrix_" + original.id] + tables).map {
                    "CREATE TABLE poc." + $0 + "(" + original.definition
                        + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
                })
            let sourceTable = "poc.matrix_" + original.id
            var expected = original.sql.map { "USE poc; " + $0 }
            var expectedCounts = counts
            for (index, table) in tables.enumerated() {
                expected += original.sql.prefix(index + 1).map {
                    "USE poc; " + $0.replacingOccurrences(of: sourceTable, with: "poc." + table)
                }
                expectedCounts += counts.prefix(index + 1)
            }
            XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
            XCTAssertEqual(plan.body.transactions, expectedCounts)
            XCTAssertEqual(
                plan.cleanup.writes.map(\.sql), ["DROP TABLE " + tables.map { "poc." + $0 }.joined(separator: ",")])
        }
    }

    func testEveryOriginalPredicateKeepsItsMatchingRetainedResult() throws {
        for (original, tables) in zip(
            originals,
            [
                ["ev_after_insert", "ev_after_update", "ev_after_add", "matrix_encodings"],
                ["ws_after_insert", "ws_after_update", "matrix_widestrings"],
                ["zw_after_insert", "zw_after_update", "zw_after_widen", "matrix_zerowidth"],
            ])
        {
            let plan = try plan(original.id)
            for (index, sql) in original.predicates.enumerated() {
                let check = plan.final.checks[index]
                XCTAssertEqual(
                    check.check.sql,
                    sql.replacingOccurrences(of: "poc.matrix_" + original.id, with: "poc." + tables[index]))
                XCTAssertEqual(check.check.expected, "1")
                _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
                XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testWritesKeepSessionResetsAndAutocommitBoundaries() throws {
        for original in originals {
            let plan = try plan(original.id)
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

    func testEncodingRowsKeepEveryByteKeyCaseAndJSONScalarType() throws {
        let initial =
            "E9\tE9\t0080FF20\tE980FF00\t410020\tE4B8AD\tFF200000\tOBJECT\t1\tDECIMAL\t1.25\n7365636F6E64\tNULL\t\tNULL\t\t\tNULL\tNULL\tNULL\tNULL\tNULL"
        let updated =
            "C958\tE9\tFF00E9\tE980FF00\t4E657874\tC3A9\tFF200000\tOBJECT\t1\tDECIMAL\t2.50\n7365636F6E64\tNULL\t\tNULL\t\t\tNULL\tNULL\tNULL\tNULL\tNULL"
        let added =
            "C958\tE9\tFF00E9\tE900FF\t4E657874\tC3A9\tFF200000\tOBJECT\t1\tDECIMAL\t2.50\t5A\n7365636F6E64\tNULL\t\tNULL\t\t\tNULL\tNULL\tNULL\tNULL\tNULL\t78"
        let final = "7365636F6E64\tNULL\t\tNULL\t\t\tNULL\tNULL\tNULL\tNULL\tNULL\t78"
        let projection =
            "SELECT HEX(id),IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(t),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(u),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(JSON_TYPE(doc),'NULL'),IFNULL(JSON_LENGTH(doc),'NULL'),IFNULL(JSON_TYPE(JSON_EXTRACT(doc,'$.n')),'NULL'),IFNULL(CAST(JSON_UNQUOTE(JSON_EXTRACT(doc,'$.n')) AS DECIMAL(3,2)),'NULL')"
        for (name, table, rows, count) in [
            ("initial-rows", "ev_after_insert", initial, 11),
            ("updated-rows", "ev_after_update", updated, 11),
            ("added-column-rows", "ev_after_add", added, 12),
            ("final-rows", "matrix_encodings", final, 12),
        ] {
            let check = try check("encodings", name)
            XCTAssertEqual(
                check.check.sql,
                projection + (count == 12 ? ",IFNULL(HEX(extra),'NULL')" : "") + " FROM poc." + table + " ORDER BY id")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(rows.utf8))
            XCTAssertTrue(
                rows.split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == count
                })
            _ = try check.result([name: rows], engine: "MyISAM", role: "target")
            for (old, wrong) in [
                ("E9", "C3A9"), ("C958", "E978"), ("FF200000", "FF20"), ("DECIMAL", "DOUBLE"), ("2.50", "1.25"),
                ("NULL", ""), ("\t\t", "\t"),
            ] where rows.contains(old) {
                XCTAssertThrowsError(
                    try check.result(
                        [name: rows.replacingOccurrences(of: old, with: wrong)], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testEncodingDefaultsKeepOriginalAndAddedBytes() throws {
        for (name, sql, value) in [
            ("original-default-bytes", "SELECT HEX(DEFAULT(u)) FROM poc.ev_after_insert WHERE id='second'", "E4B8AD"),
            (
                "added-default-bytes",
                "SELECT HEX(DEFAULT(u)),HEX(DEFAULT(extra)) FROM poc.ev_after_add WHERE id='second'", "E4B8AD\t78"
            ),
        ] {
            let check = try check("encodings", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(check.check.expected, value)
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([name: value + "00"], engine: "MyISAM", role: "target"))
        }
    }

    func testWideStringsCheckCompleteRepeatedPayloadsAndShortReplacement() throws {
        let check = try check("widestrings", "complete-large-payloads")
        XCTAssertEqual(
            check.check.sql,
            "SELECT id,OCTET_LENGTH(v),OCTET_LENGTH(b),HEX(v)=REPEAT('E9',18000),HEX(b)=REPEAT('FF00',9000) FROM poc.ws_after_insert ORDER BY id"
        )
        XCTAssertEqual(check.check.expected, "1\t18000\t18000\t1\t1")
        for (count, v, b) in [(18000, "1", "1"), (18000, "0", "1"), (18000, "1", "0"), (17999, "1", "1")] {
            let actual = "1\t\(count)\t18000\t\(v)\t\(b)"
            if count == 18000 && v == "1" && b == "1" {
                _ = try check.result([check.id: actual], engine: "MyISAM", role: "target")
            } else {
                XCTAssertThrowsError(try check.result([check.id: actual], engine: "MyISAM", role: "target"))
            }
        }
        let changed = try self.check("widestrings", "updated-row")
        XCTAssertEqual(changed.check.sql, "SELECT id,HEX(v),HEX(b) FROM poc.ws_after_update ORDER BY id")
        XCTAssertEqual(changed.check.expected, "1\t00FF\tFF")
        XCTAssertThrowsError(try changed.result([changed.id: "1\tFF\tFF"], engine: "MyISAM", role: "target"))
        let empty = try self.check("widestrings", "empty-final-table")
        XCTAssertEqual(empty.check.sql, "SELECT id,HEX(v),HEX(b) FROM poc.matrix_widestrings ORDER BY id")
        XCTAssertEqual(empty.check.expected, "")
        _ = try empty.result([empty.id: ""], engine: "MyISAM", role: "target")
        XCTAssertThrowsError(try empty.result([empty.id: changed.check.expected], engine: "MyISAM", role: "target"))
    }

    func testZeroLengthRowsKeepEmptyNullAndWidenedValues() throws {
        for (name, table, rows) in [
            ("initial-rows", "zw_after_insert", "1\t\t\t\t\t\n2\tNULL\tNULL\tNULL\tNULL\tNULL"),
            ("updated-rows", "zw_after_update", "1\tNULL\tNULL\tNULL\tNULL\tNULL\n2\t\t\t\t\t"),
            ("widened-rows", "zw_after_widen", "1\tNULL\t6869\tNULL\tFF00\t4E2D\n2\t\t\t\t\t"),
            ("final-rows", "matrix_zerowidth", "1\tNULL\t\tNULL\t\t"),
        ] {
            let check = try check("zerowidth", name)
            XCTAssertEqual(
                check.check.sql,
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(u),'NULL') FROM poc."
                    + table + " ORDER BY id")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(rows.utf8))
            XCTAssertTrue(
                rows.split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == 6
                })
            _ = try check.result([name: rows], engine: "MyISAM", role: "target")
            for (old, wrong) in [("NULL", ""), ("\t\t", "\t"), ("FF00", "FF"), ("4E2D", "E4B8AD")]
            where rows.contains(old) {
                XCTAssertThrowsError(
                    try check.result(
                        [name: rows.replacingOccurrences(of: old, with: wrong)], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testZeroLengthSchemasAndDefaultBytesKeepWidenAndShrink() throws {
        for (name, table, width) in [
            ("initial", "zw_after_insert", 0), ("widened", "zw_after_widen", 4), ("final", "matrix_zerowidth", 0),
        ] {
            let schema = try check("zerowidth", name + "-column-types")
            let expected =
                "c\tchar(0)\tutf8mb4\tutf8mb4_bin\nv\tvarchar(\(width))\tutf8mb4\tutf8mb4_bin\nb\tbinary(0)\tNULL\tNULL\nw\tvarbinary(\(width))\tNULL\tNULL\nu\tvarchar(\(width))\tutf16\tutf16_bin"
            XCTAssertEqual(
                schema.check.sql,
                "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='"
                    + table + "' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION")
            XCTAssertEqual(schema.check.expected, expected)
            _ = try schema.result([schema.id: expected], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(
                try schema.result(
                    [schema.id: expected.replacingOccurrences(of: "varchar(\(width))", with: "varchar(8)")],
                    engine: "MyISAM", role: "target"))
            let defaults = try check("zerowidth", name + "-default-bytes")
            XCTAssertEqual(
                defaults.check.sql,
                "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(b)),HEX(DEFAULT(w)),HEX(DEFAULT(u)) FROM poc."
                    + table + " WHERE id=1")
            let bytes = width == 4 ? "\t78\t\tFF\t4E2D" : "\t\t\t\t"
            XCTAssertEqual(Data(defaults.check.expected.utf8), Data(bytes.utf8))
            _ = try defaults.result([defaults.id: bytes], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try defaults.result([defaults.id: bytes + "00"], engine: "MyISAM", role: "target"))
        }
    }

    func testProgressRequiresExactCountsGTIDsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("encodings", 16, 6, 14), ("widestrings", 9, 3, 6), ("zerowidth", 21, 7, 18),
        ] {
            let plan = try plan(id)
            XCTAssertEqual(plan.prepare.transactionCount + plan.body.transactionCount, transactions)
            XCTAssertEqual(plan.expectedDDL, ddl)
            XCTAssertEqual(plan.expectedRows, rows)
            let before: [String: Any] = ["transactionsApplied": 0, "ddlApplied": 0, "rowsApplied": 0]
            var after: [String: Any] = [
                "transactionsApplied": transactions, "ddlApplied": ddl, "rowsApplied": rows,
                "appliedGTIDSet": "uuid:1-\(transactions)",
                "appliedPosition": ["file": "binlog.000001", "position": "1000"],
            ]
            let end = Boundary(file: "binlog.000001", position: 1000, gtids: "uuid:1-\(transactions)")
            XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
            after["transactionsApplied"] = transactions - 1
            XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
            after["transactionsApplied"] = transactions + 1
            after["ddlApplied"] = ddl + 1
            after["appliedGTIDSet"] = "uuid:1-\(transactions+1)"
            let cleaned = Boundary(file: end.file, position: end.position, gtids: "uuid:1-\(transactions+1)")
            XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
            after["appliedPosition"] = ["file": end.file, "position": "999"]
            XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
        }
    }

    func testTitlesCleanupAndAllOptInFixturesRemain() throws {
        for (id, title, checkCount) in [
            ("encodings", "Character and binary strings: encodings, key changes and JSON DECIMAL values", 10),
            ("widestrings", "VARCHAR and VARBINARY: large values, short updates and DELETE", 6),
            ("zerowidth", "String data types: zero-length columns, NULL values and width changes", 14),
        ] {
            let test = try fixture(id)
            let plan = try plan(id)
            XCTAssertEqual(test.displayName, title)
            XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-" + id }?.test.name, title)
            XCTAssertEqual(plan.final.checks.count, checkCount)
            XCTAssertEqual(plan.final.databases, ["poc"])
            XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
            XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
        }
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "zerowidth", "identifiercase", "unicodeidentifiers", "encodings", "widestrings",
                "bits", "enumzero", "choices", "widechoices", "integers", "decimal",
            ])
    }
}
