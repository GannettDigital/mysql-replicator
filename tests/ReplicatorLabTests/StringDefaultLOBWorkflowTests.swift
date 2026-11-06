import Foundation
import XCTest

@testable import ReplicatorLabCore

final class StringDefaultLOBWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "binarydefaults",
            definition:
                "id INT PRIMARY KEY,b BINARY(5) DEFAULT X'ff0001',v VARBINARY(8) DEFAULT 0xFF0001,a BINARY(5) DEFAULT 'hi',e VARBINARY(5) DEFAULT X'',z BINARY(0) DEFAULT X'',c CHAR(4) CHARACTER SET binary DEFAULT X'ff00',n BINARY(8) DEFAULT 1e2,q VARBINARY(8) DEFAULT '1e2'",
            sql: [
                "INSERT INTO poc.matrix_binarydefaults(id) VALUES(1),(2)",
                "ALTER TABLE poc.matrix_binarydefaults ALTER b SET DEFAULT X'00ff02',ALTER v SET DEFAULT B'11111111',ADD extra VARBINARY(8) DEFAULT X'800003'; UPDATE poc.matrix_binarydefaults SET b=DEFAULT,v=DEFAULT WHERE id=1",
                "ALTER TABLE poc.matrix_binarydefaults MODIFY a BINARY(6) DEFAULT X'ff0004',ALTER e DROP DEFAULT; INSERT INTO poc.matrix_binarydefaults(id,e) VALUES(3,NULL); UPDATE poc.matrix_binarydefaults SET v=X'0000ff00' WHERE id=1; DELETE FROM poc.matrix_binarydefaults WHERE id=2",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(HEX(b)='FF00010000' AND HEX(v)='FF0001' AND HEX(a)='6869000000' AND HEX(e)='' AND HEX(z)='' AND HEX(c)='FF000000' AND HEX(n)='3130300000000000' AND HEX(q)='316532')=2 FROM poc.matrix_binarydefaults",
                "SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(b)='00FF020000' AND HEX(v)='FF')=1 AND SUM(HEX(extra)='800003')=2 FROM poc.matrix_binarydefaults",
                "SELECT COUNT(*)=2 AND SUM(id=3 AND HEX(a)='FF0004000000' AND e IS NULL)=1 AND SUM(id=1 AND HEX(v)='0000FF00')=1 FROM poc.matrix_binarydefaults",
            ]),
        .init(
            id: "textdefaults",
            definition:
                "id INT PRIMARY KEY,c CHAR(4) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT '😀  ',v VARCHAR(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT '😀  ',l VARCHAR(8) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT X'ff00',w CHAR(4) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X'4e2d',n CHAR(8) DEFAULT 1e2,q VARCHAR(8) DEFAULT '1e2',b CHAR(8) CHARACTER SET binary DEFAULT 1e2,d VARCHAR(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'é'",
            sql: [
                "INSERT INTO poc.matrix_textdefaults(id) VALUES(1),(2)",
                "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,PAD_CHAR_TO_FULL_LENGTH'; ALTER TABLE poc.matrix_textdefaults ALTER c SET DEFAULT '中  ',ALTER l SET DEFAULT X'e900',ADD extra VARCHAR(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT '😀\\0'; UPDATE poc.matrix_textdefaults SET c=DEFAULT,l=DEFAULT WHERE id=1",
                "ALTER TABLE poc.matrix_textdefaults MODIFY w VARCHAR(8) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X'20200020',ALTER q SET DEFAULT 1e3,ALTER v DROP DEFAULT; INSERT INTO poc.matrix_textdefaults(id,v) VALUES(3,NULL); DELETE FROM poc.matrix_textdefaults WHERE id=2",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(HEX(c)='F09F9880' AND HEX(v)='F09F98802020' AND HEX(l)='FF00' AND HEX(w)='4E2D' AND n='100' AND q='1e2' AND HEX(b)='3130300000000000' AND HEX(d)='65CC81')=2 FROM poc.matrix_textdefaults",
                "SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(c)='E4B8AD' AND HEX(l)='E900')=1 AND SUM(HEX(extra)='F09F988000')=2 FROM poc.matrix_textdefaults",
                "SELECT COUNT(*)=2 AND SUM(id=3 AND HEX(w)='20200020' AND q='1000' AND v IS NULL)=1 FROM poc.matrix_textdefaults",
            ]),
        .init(
            id: "fixed", definition: "id INT PRIMARY KEY,c CHAR(255),b BINARY(8)",
            sql: [
                "INSERT INTO poc.matrix_fixed VALUES(1,CONVERT(0xF09F988065CC812020 USING utf8mb4),0x00FF),(2,'',X''),(3,NULL,NULL)",
                "UPDATE poc.matrix_fixed SET c=REPEAT('x',255),b=0x0102030405060708 WHERE id=1",
                "DELETE FROM poc.matrix_fixed WHERE id IN (1,3)",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=1 AND HEX(c)='F09F988065CC81' AND HEX(b)='00FF000000000000'",
                "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=1 AND CHAR_LENGTH(c)=255 AND HEX(b)='0102030405060708'",
                "SELECT COUNT(*)=1 FROM poc.matrix_fixed WHERE id=2 AND HEX(b)='0000000000000000'",
            ]),
        .init(
            id: "lob",
            definition:
                "id INT PRIMARY KEY,a TINYTEXT,b TEXT,c MEDIUMTEXT,d LONGTEXT,e TINYBLOB,f BLOB,g MEDIUMBLOB,h LONGBLOB,KEY prefix_key(b(10))",
            sql: [
                "INSERT INTO poc.matrix_lob VALUES(1,CONVERT(0x0027F09F988065CC812020 USING utf8mb4),REPEAT('x',1000),REPEAT('y',70000),'',0x00FF275C,REPEAT(0xFF,1000),REPEAT(0x00FF,35000),NULL)",
                "UPDATE poc.matrix_lob SET a=NULL,b='',c='short',e=X'',h=0x00FF WHERE id=1",
                "DELETE FROM poc.matrix_lob WHERE id=1",
            ],
            predicates: [
                "SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE HEX(a)='0027F09F988065CC812020' AND OCTET_LENGTH(c)=70000 AND OCTET_LENGTH(g)=70000 AND h IS NULL",
                "SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE a IS NULL AND b='' AND c='short' AND e=X'' AND HEX(h)='00FF'",
                "SELECT COUNT(*)=0 FROM poc.matrix_lob",
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

    private func metadataOwner(_ id: String) -> String {
        ["binarydefaults", "textdefaults"].contains(id)
            ? MetadataDiscoveryCases.encodings.id : MetadataDiscoveryCases.columns.id
    }

    func testColdMetadataKeepsEachDefinitionAndFirstInsertOnEveryProfile() throws {
        for original in originals {
            XCTAssertEqual(MetadataDiscoveryCases.owner(original.id), metadataOwner(original.id))
            XCTAssertEqual(MetadataDiscoveryCases.representative(original.id), original.id)
            for profile in LabProfile.allCases {
                XCTAssertTrue(try fixture(original.id).applies(to: profile))
                let cold = try XCTUnwrap(
                    MetadataDiscoveryCases.fixtures(metadataOwner(original.id), profile: profile).first {
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
            (originals[0], ["bd_after_insert", "bd_after_defaults"], [1, 2, 4]),
            (originals[1], ["td_after_insert", "td_after_defaults"], [1, 2, 3]),
            (originals[2], ["fv_after_insert", "fv_after_update"], [1, 1, 1]),
            (originals[3], ["lb_after_insert", "lb_after_update"], [1, 1, 1]),
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

    func testPadModeStaysInOriginalRequestAndResetsBeforeFollowingWrites() throws {
        let plan = try plan("textdefaults")
        let queries = try LabSQLPhase.queries(
            plan.body.writes, session: LabProfile.forward.session, status: "SHOW BINARY LOG STATUS")
        for (index, write) in plan.body.writes.enumerated() {
            let sql = queries[index * 4].sql
            XCTAssertTrue(sql.hasPrefix(LabProfile.forward.session + "\n"))
            if write.sql.contains("PAD_CHAR_TO_FULL_LENGTH") {
                XCTAssertTrue(
                    write.sql.hasPrefix(
                        "USE poc; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,PAD_CHAR_TO_FULL_LENGTH'; ALTER TABLE"
                    ))
                XCTAssertEqual(plan.body.transactions[index], 2)
                let mode = try XCTUnwrap(sql.range(of: "PAD_CHAR_TO_FULL_LENGTH"))
                let alter = try XCTUnwrap(sql.range(of: "ALTER TABLE"))
                let update = try XCTUnwrap(sql.range(of: "UPDATE poc."))
                XCTAssertLessThan(mode.lowerBound, alter.lowerBound)
                XCTAssertLessThan(alter.lowerBound, update.lowerBound)
            } else {
                XCTAssertFalse(sql.contains("PAD_CHAR_TO_FULL_LENGTH"))
            }
        }
        XCTAssertEqual(plan.body.writes.filter { $0.sql.contains("PAD_CHAR_TO_FULL_LENGTH") }.count, 2)
    }

    func testBinaryDefaultRowsKeepPaddingEmptyNullAndWidthChanges() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL') FROM poc.bd_after_insert ORDER BY id",
                "1\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532\n2\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532"
            ),
            (
                "changed-default-rows",
                "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.bd_after_defaults ORDER BY id",
                "1\t00FF020000\tFF\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003\n2\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_binarydefaults ORDER BY id",
                "1\t00FF020000\t0000FF00\t686900000000\t\t\tFF000000\t3130300000000000\t316532\t800003\n3\t00FF020000\tFF\tFF0004000000\tNULL\t\tFF000000\t3130300000000000\t316532\t800003"
            ),
        ] {
            let check = try check("binarydefaults", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("FF00010000", "FF0001"), ("686900000000", "6869000000"), ("F09F98802020", "F09F9880"),
                    ("65CC81", "C3A9"), ("20200020", "00200020"), ("316532", "313030"), ("70000", "69999"),
                    ("00FF275C", "00FF2727"), ("NULL", ""), ("\t\t", "\tNULL\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testCharacterDefaultRowsKeepEncodingSpacesAndExactUnicodeBytes() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL') FROM poc.td_after_insert ORDER BY id",
                "1\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81\n2\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81"
            ),
            (
                "changed-default-rows",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.td_after_defaults ORDER BY id",
                "1\tE4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000\n2\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000"
            ),
            (
                "final-rows",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_textdefaults ORDER BY id",
                "1\tE4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000\n3\tE4B8AD\tNULL\tE900\t20200020\t313030\t31303030\t3130300000000000\t65CC81\tF09F988000"
            ),
        ] {
            let check = try check("textdefaults", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("FF00010000", "FF0001"), ("686900000000", "6869000000"), ("F09F98802020", "F09F9880"),
                    ("65CC81", "C3A9"), ("20200020", "00200020"), ("316532", "313030"), ("70000", "69999"),
                    ("00FF275C", "00FF2727"), ("NULL", ""), ("\t\t", "\tNULL\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testFixedLengthRowsKeepFullValuesEmptyAndNull() throws {
        for (name, sql, value) in [
            (
                "initial-rows",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.fv_after_insert ORDER BY id",
                "1\tF09F988065CC81\t00FF000000000000\n2\t\t0000000000000000\n3\tNULL\tNULL"
            ),
            (
                "updated-rows",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.fv_after_update ORDER BY id",
                "1\t787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878\t0102030405060708\n2\t\t0000000000000000\n3\tNULL\tNULL"
            ),
            (
                "final-empty-row",
                "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.matrix_fixed ORDER BY id",
                "2\t\t0000000000000000"
            ),
        ] {
            let check = try check("fixed", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("FF00010000", "FF0001"), ("686900000000", "6869000000"), ("F09F98802020", "F09F9880"),
                    ("65CC81", "C3A9"), ("20200020", "00200020"), ("316532", "313030"), ("70000", "69999"),
                    ("00FF275C", "00FF2727"), ("NULL", ""), ("\t\t", "\tNULL\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testCompleteLOBRowsUseAllBytesAndRetainEveryFamily() throws {
        for (name, sql, value) in [
            (
                "complete-inserted-payloads",
                "SELECT id,IFNULL(HEX(a),'NULL'),OCTET_LENGTH(b),HEX(b)=REPEAT('78',1000),OCTET_LENGTH(c),HEX(c)=REPEAT('79',70000),IFNULL(HEX(d),'NULL'),IFNULL(HEX(e),'NULL'),OCTET_LENGTH(f),HEX(f)=REPEAT('FF',1000),OCTET_LENGTH(g),HEX(g)=REPEAT('00FF',35000),IFNULL(HEX(h),'NULL') FROM poc.lb_after_insert ORDER BY id",
                "1\t0027F09F988065CC812020\t1000\t1\t70000\t1\t\t00FF275C\t1000\t1\t70000\t1\tNULL"
            ),
            (
                "complete-updated-payloads",
                "SELECT id,IFNULL(HEX(a),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(e),'NULL'),OCTET_LENGTH(f),HEX(f)=REPEAT('FF',1000),OCTET_LENGTH(g),HEX(g)=REPEAT('00FF',35000),IFNULL(HEX(h),'NULL') FROM poc.lb_after_update ORDER BY id",
                "1\tNULL\t\t73686F7274\t\t\t1000\t1\t70000\t1\t00FF"
            ),
            ("empty-final-table", "SELECT id FROM poc.matrix_lob ORDER BY id", ""),
        ] {
            let check = try check("lob", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("FF00010000", "FF0001"), ("686900000000", "6869000000"), ("F09F98802020", "F09F9880"),
                    ("65CC81", "C3A9"), ("20200020", "00200020"), ("316532", "313030"), ("70000", "69999"),
                    ("00FF275C", "00FF2727"), ("NULL", ""), ("\t\t", "\tNULL\t"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testStoredDefaultsAndDeclaredTypesRemainSeparateFromRows() throws {
        for (id, name, sql, value) in [
            (
                "binarydefaults", "initial-stored-defaults",
                "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(e)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)) FROM poc.bd_after_insert WHERE id=1",
                "FF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532"
            ),
            (
                "binarydefaults", "initial-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bd_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(5)\tYES\t0\ne\tvarbinary(5)\tYES\t0\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0"
            ),
            (
                "binarydefaults", "changed-stored-defaults",
                "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(e)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(extra)) FROM poc.bd_after_defaults WHERE id=1",
                "00FF020000\tFF\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003"
            ),
            (
                "binarydefaults", "changed-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bd_after_defaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(5)\tYES\t0\ne\tvarbinary(5)\tYES\t0\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0\nextra\tvarbinary(8)\tYES\t0"
            ),
            (
                "binarydefaults", "final-stored-defaults",
                "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(extra)) FROM poc.matrix_binarydefaults WHERE id=1",
                "00FF020000\tFF\tFF0004000000\t\tFF000000\t3130300000000000\t316532\t800003"
            ),
            (
                "binarydefaults", "final-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_binarydefaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(6)\tYES\t0\ne\tvarbinary(5)\tYES\t1\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0\nextra\tvarbinary(8)\tYES\t0"
            ),
            (
                "textdefaults", "initial-stored-defaults",
                "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)) FROM poc.td_after_insert WHERE id=1",
                "F09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81"
            ),
            (
                "textdefaults", "initial-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='td_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tchar(4)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
            ),
            (
                "textdefaults", "changed-stored-defaults",
                "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)),HEX(DEFAULT(extra)) FROM poc.td_after_defaults WHERE id=1",
                "E4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000"
            ),
            (
                "textdefaults", "changed-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='td_after_defaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tchar(4)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nextra\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
            ),
            (
                "textdefaults", "final-stored-defaults",
                "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)),HEX(DEFAULT(extra)) FROM poc.matrix_textdefaults WHERE id=1",
                "E4B8AD\tE900\t20200020\t313030\t31303030\t3130300000000000\t65CC81\tF09F988000"
            ),
            (
                "textdefaults", "final-column-attributes",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_textdefaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t1\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tvarchar(8)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nextra\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
            ),
            (
                "fixed", "fixed-length-declarations",
                "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fv_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "c\tchar(255)\tutf8mb4\tutf8mb4_bin\tYES\nb\tbinary(8)\tNULL\tNULL\tYES"
            ),
            (
                "lob", "all-blob-text-declarations",
                "SELECT COLUMN_NAME,DATA_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='lb_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                "a\ttinytext\tutf8mb4\tutf8mb4_bin\tYES\nb\ttext\tutf8mb4\tutf8mb4_bin\tYES\nc\tmediumtext\tutf8mb4\tutf8mb4_bin\tYES\nd\tlongtext\tutf8mb4\tutf8mb4_bin\tYES\ne\ttinyblob\tNULL\tNULL\tYES\nf\tblob\tNULL\tNULL\tYES\ng\tmediumblob\tNULL\tNULL\tYES\nh\tlongblob\tNULL\tNULL\tYES"
            ),
            (
                "lob", "text-prefix-index",
                "SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='lb_after_insert' AND INDEX_NAME='prefix_key' ORDER BY SEQ_IN_INDEX",
                "prefix_key\t1\t1\tb\t10"
            ),
        ] {
            let check = try check(id, name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            _ = try check.result([name: value], engine: "MyISAM", role: "target")
            for wrong in [
                value + "0", value.replacingOccurrences(of: "binary(6)", with: "binary(5)"),
                value.replacingOccurrences(of: "utf16_bin", with: "utf8mb4_bin"),
                value.replacingOccurrences(of: "varbinary(8)", with: "binary(8)"),
                value.replacingOccurrences(of: "prefix_key\t1\t1\tb\t10", with: "prefix_key\t1\t1\tb\t9"),
            ] where wrong != value {
                XCTAssertThrowsError(try check.result([name: wrong], engine: "MyISAM", role: "target"))
            }
        }
    }

    func testDroppedDefaultsUseMetadataInsteadOfInvalidDefaultReads() throws {
        for (id, field) in [("binarydefaults", "e"), ("textdefaults", "v")] {
            let value = try check(id, "final-stored-defaults")
            XCTAssertFalse(value.check.sql.contains("DEFAULT(" + field + ")"))
            let initial = try check(id, "initial-stored-defaults")
            XCTAssertTrue(initial.check.sql.contains("DEFAULT(" + field + ")"))
            let schema = try check(id, "final-column-attributes")
            let row = try XCTUnwrap(
                schema.check.expected.components(separatedBy: "\n").first { $0.hasPrefix(field + "\t") })
            XCTAssertTrue(row.hasSuffix("\tYES\t1"))
        }
    }

    func testLargePayloadChecksCompareFullRepeatedValuesAndPrefixIndex() throws {
        let inserted = try check("lob", "complete-inserted-payloads").check.sql
        let updated = try check("lob", "complete-updated-payloads").check.sql
        XCTAssertTrue(inserted.contains("HEX(b)=REPEAT('78',1000)"))
        XCTAssertTrue(inserted.contains("HEX(c)=REPEAT('79',70000)"))
        for sql in [inserted, updated] {
            XCTAssertTrue(sql.contains("HEX(f)=REPEAT('FF',1000)"))
            XCTAssertTrue(sql.contains("HEX(g)=REPEAT('00FF',35000)"))
            XCTAssertFalse(sql.uppercased().contains("SHA"))
            XCTAssertFalse(sql.uppercased().contains("MD5"))
        }
        let index = try check("lob", "text-prefix-index")
        XCTAssertEqual(index.check.expected, "prefix_key\t1\t1\tb\t10")
    }

    func testProgressRejectsWrongCountsGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("binarydefaults", 14, 6, 11), ("textdefaults", 13, 6, 10), ("fixed", 9, 3, 13), ("lob", 9, 3, 6),
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
            let expected = ["binarydefaults": 12, "textdefaults": 12, "fixed": 7, "lob": 8]
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
                "unicodeidentifiers", "encodings", "widestrings", "json", "typedjson", "floatbounds", "zerofill",
                "fixedfloating",
                "floating", "bits", "fixed", "enumzero", "choices", "widechoices", "integers", "decimal", "temporal",
                "precision", "lob", "defaults", "floatingautofloat", "floatingautodouble", "floatingautofixedfloat",
                "floatingautounsigneddouble",
            ])
    }
}
