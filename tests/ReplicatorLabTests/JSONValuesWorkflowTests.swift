import Foundation
import XCTest

@testable import ReplicatorLabCore

final class JSONValuesWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "json", definition: "id INT PRIMARY KEY,doc JSON",
            sql: [
                "INSERT INTO poc.matrix_json VALUES (1,JSON_OBJECT('n',CAST('18446744073709551615' AS UNSIGNED),'a',JSON_ARRAY(1,true,NULL))),(2,'null'),(3,NULL),(4,JSON_QUOTE(CONVERT(0xF09F988065CC81 USING utf8mb4))),(5,'1.0'),(6,JSON_OBJECT())",
                "UPDATE poc.matrix_json SET id=11,doc=JSON_SET(doc,'$.n',CAST('-9223372036854775808' AS SIGNED),'$.s',JSON_ARRAY('x','y')) WHERE id=1",
                "ALTER TABLE poc.matrix_json ADD extra JSON; UPDATE poc.matrix_json SET doc=JSON_ARRAY(9007199254740993,1.25e0),extra='true' WHERE id=5",
                "DELETE FROM poc.matrix_json WHERE id IN (2,4,5,6,11)",
            ],
            predicates: [
                "SELECT COUNT(*)=6 AND SUM(doc IS NULL)=1 AND SUM(JSON_TYPE(doc)='NULL')=1 AND SUM(JSON_TYPE(doc)='DOUBLE')=1 FROM poc.matrix_json",
                "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=11 AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.n'))='-9223372036854775808' AND JSON_LENGTH(JSON_EXTRACT(doc,'$.s'))=2",
                "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=5 AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$[0]'))='9007199254740993' AND JSON_TYPE(JSON_EXTRACT(doc,'$[1]'))='DOUBLE' AND JSON_TYPE(extra)='BOOLEAN'",
                "SELECT COUNT(*)=1 FROM poc.matrix_json WHERE id=3 AND doc IS NULL",
            ]),
        .init(
            id: "typedjson",
            definition:
                "id INT PRIMARY KEY,doc JSON,ts TIMESTAMP(6) NULL,b TINYBLOB,c BLOB,d MEDIUMBLOB,e LONGBLOB,f VARBINARY(4),g BINARY(4),bits BIT(9)",
            sql: [
                "INSERT INTO poc.matrix_typedjson VALUES(1,NULL,'2024-02-29 12:34:56.123456',0x00FF,0x0027,0xFF00,0x0102,0x00FF,0x00FF,511),(2,NULL,'2024-02-29 12:34:56.123456',0x00FF,0x0027,0xFF00,0x0102,0x00FF,0x00FF,511)",
                "UPDATE poc.matrix_typedjson SET doc=JSON_OBJECT('decimal',CAST('-12345678901234567890123456789012345.123456789012345678901234567890' AS DECIMAL(65,30)),'date',CAST('2024-02-29' AS DATE),'time',CAST('-838:59:58.123456' AS TIME(6)),'datetime',CAST('2024-02-29 12:34:56.123456' AS DATETIME(6)),'timestamp',ts,'tiny',b,'blob',c,'medium',d,'long',e,'varbinary',f,'binary',g,'bits',bits)",
                "UPDATE poc.matrix_typedjson SET doc=JSON_ARRAY(CAST('0000-00-00' AS DATE),CAST('0000-00-00 00:00:00' AS DATETIME),CAST('18446744073709551615' AS UNSIGNED),CAST('1.00' AS DECIMAL(3,2))) WHERE id=1",
                "DELETE FROM poc.matrix_typedjson",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(doc IS NULL)=2 FROM poc.matrix_typedjson",
                "SELECT COUNT(*)=2 FROM poc.matrix_typedjson WHERE JSON_TYPE(JSON_EXTRACT(doc,'$.decimal'))='DECIMAL' AND JSON_UNQUOTE(JSON_EXTRACT(doc,'$.decimal'))='-12345678901234567890123456789012345.123456789012345678901234567890' AND JSON_TYPE(JSON_EXTRACT(doc,'$.date'))='DATE' AND JSON_TYPE(JSON_EXTRACT(doc,'$.time'))='TIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$.datetime'))='DATETIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$.timestamp'))='TIMESTAMP' AND JSON_TYPE(JSON_EXTRACT(doc,'$.bits'))='BIT' AND JSON_TYPE(JSON_EXTRACT(doc,'$.tiny'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.blob'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.medium'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.long'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.varbinary'))='BLOB' AND JSON_TYPE(JSON_EXTRACT(doc,'$.binary'))='BLOB'",
                "SELECT COUNT(*)=1 FROM poc.matrix_typedjson WHERE id=1 AND JSON_TYPE(JSON_EXTRACT(doc,'$[0]'))='DATE' AND JSON_TYPE(JSON_EXTRACT(doc,'$[1]'))='DATETIME' AND JSON_TYPE(JSON_EXTRACT(doc,'$[2]'))='UNSIGNED INTEGER' AND JSON_TYPE(JSON_EXTRACT(doc,'$[3]'))='DECIMAL'",
                "SELECT COUNT(*)=0 FROM poc.matrix_typedjson",
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

    func testColdMetadataKeepsJSONRepresentativeAndOriginalFirstInsert() throws {
        XCTAssertEqual(MetadataDiscoveryCases.representative("typedjson"), "json")
        XCTAssertEqual(MetadataDiscoveryCases.representative("jsonpartial"), "json")
        for profile in LabProfile.allCases {
            for original in originals { XCTAssertTrue(try fixture(original.id).applies(to: profile)) }
            let cold = try XCTUnwrap(
                MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.columns.id, profile: profile).first {
                    $0.id == "json"
                })
            XCTAssertEqual(cold.definition, originals[0].definition)
            XCTAssertEqual(cold.phases[0].sql, originals[0].sql[0])
            XCTAssertEqual(cold.phases[0].check, originals[0].predicates[0])
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
            (originals[0], ["jv_after_insert", "jv_after_key_update", "jv_after_add"], [1, 1, 2, 1]),
            (originals[1], ["jt_after_insert", "jt_after_object", "jt_after_array"], [1, 1, 1, 1]),
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

    func testDocumentValuesAndNullStates() throws {
        for (name, sql, value) in [
            (
                "inserted-document-types",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jv_after_insert ORDER BY id",
                "1\tOBJECT\t2\n2\tNULL\t1\n3\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\n5\tDOUBLE\t1\n6\tOBJECT\t0"
            ),
            (
                "inserted-object-values",
                "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.a[0]'),JSON_UNQUOTE(doc->'$.a[0]'),JSON_TYPE(doc->'$.a[1]'),JSON_UNQUOTE(doc->'$.a[1]'),JSON_TYPE(doc->'$.a[2]') FROM poc.jv_after_insert WHERE id=1",
                "UNSIGNED INTEGER\t18446744073709551615\tARRAY\t3\tINTEGER\t1\tBOOLEAN\ttrue\tNULL"
            ),
            (
                "exact-unicode-string", "SELECT HEX(JSON_UNQUOTE(doc)) FROM poc.jv_after_insert WHERE id=4",
                "F09F988065CC81"
            ),
            (
                "double-root-type-and-value",
                "SELECT JSON_TYPE(doc),CAST(JSON_UNQUOTE(doc) AS DECIMAL(3,2)) FROM poc.jv_after_insert WHERE id=5",
                "DOUBLE\t1.00"
            ),
            (
                "key-update-document-types",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jv_after_key_update ORDER BY id",
                "2\tNULL\t1\n3\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\n5\tDOUBLE\t1\n6\tOBJECT\t0\n11\tOBJECT\t3"
            ),
            (
                "key-update-object-values",
                "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.s'),JSON_LENGTH(doc->'$.s'),HEX(JSON_UNQUOTE(doc->'$.s[0]')),HEX(JSON_UNQUOTE(doc->'$.s[1]')) FROM poc.jv_after_key_update WHERE id=11",
                "INTEGER\t-9223372036854775808\t3\tARRAY\t2\t78\t79"
            ),
            (
                "added-column-object-values",
                "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.s'),JSON_LENGTH(doc->'$.s'),HEX(JSON_UNQUOTE(doc->'$.s[0]')),HEX(JSON_UNQUOTE(doc->'$.s[1]')) FROM poc.jv_after_add WHERE id=11",
                "INTEGER\t-9223372036854775808\t3\tARRAY\t2\t78\t79"
            ),
            (
                "added-column-document-types",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL'),IFNULL(JSON_TYPE(extra),'SQL_NULL') FROM poc.jv_after_add ORDER BY id",
                "2\tNULL\t1\tSQL_NULL\n3\tSQL_NULL\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\tSQL_NULL\n5\tARRAY\t2\tBOOLEAN\n6\tOBJECT\t0\tSQL_NULL\n11\tOBJECT\t3\tSQL_NULL"
            ),
            (
                "exact-large-integer-array",
                "SELECT JSON_TYPE(doc->'$[0]'),JSON_UNQUOTE(doc->'$[0]'),JSON_TYPE(doc->'$[1]'),CAST(JSON_UNQUOTE(doc->'$[1]') AS DECIMAL(3,2)),JSON_UNQUOTE(extra) FROM poc.jv_after_add WHERE id=5",
                "INTEGER\t9007199254740993\tDOUBLE\t1.25\ttrue"
            ),
            (
                "final-sql-null-row",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL'),IFNULL(JSON_TYPE(extra),'SQL_NULL') FROM poc.matrix_json ORDER BY id",
                "3\tSQL_NULL\tSQL_NULL\tSQL_NULL"
            ),
        ] {
            let check = try check("json", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("SQL_NULL", "NULL"), ("UNSIGNED INTEGER", "INTEGER"), ("DECIMAL", "DOUBLE"),
                    ("TIMESTAMP", "DATETIME"), ("BLOB", "STRING"), ("BIT", "INTEGER"),
                    ("18446744073709551615", "18446744073709551616"), ("9007199254740993", "9007199254740992"),
                    ("65CC81", "C3A9"), (".123456", ".123455"), ("AP8AAA==", "AP8="), ("Af8=", "Af4="),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testNativeScalarValuesAndUnchangedOrdinaryFields() throws {
        for (name, sql, value) in [
            (
                "jt_after_insert-ordinary-fields",
                "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_insert ORDER BY id",
                "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
            ),
            (
                "jt_after_object-ordinary-fields",
                "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_object ORDER BY id",
                "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
            ),
            (
                "jt_after_array-ordinary-fields",
                "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_array ORDER BY id",
                "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
            ),
            (
                "inserted-sql-null-documents",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_insert ORDER BY id",
                "1\tSQL_NULL\tSQL_NULL\n2\tSQL_NULL\tSQL_NULL"
            ),
            (
                "object-types-and-shape",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_object ORDER BY id",
                "1\tOBJECT\t12\n2\tOBJECT\t12"
            ),
            (
                "array-and-unchanged-object",
                "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_array ORDER BY id",
                "1\tARRAY\t4\n2\tOBJECT\t12"
            ),
            (
                "object-scalar-values",
                "SET time_zone='+00:00'; SELECT id,JSON_TYPE(doc->'$.decimal'),JSON_UNQUOTE(doc->'$.decimal'),JSON_TYPE(doc->'$.date'),JSON_UNQUOTE(doc->'$.date'),JSON_TYPE(doc->'$.time'),JSON_UNQUOTE(doc->'$.time'),JSON_TYPE(doc->'$.datetime'),JSON_UNQUOTE(doc->'$.datetime'),JSON_TYPE(doc->'$.timestamp'),JSON_UNQUOTE(doc->'$.timestamp') FROM poc.jt_after_object ORDER BY id",
                "1\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456\n2\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456"
            ),
            (
                "object-scalar-values-binary-payloads",
                "SELECT id,JSON_TYPE(doc->'$.tiny'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.tiny'),':',-1),JSON_TYPE(doc->'$.blob'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.blob'),':',-1),JSON_TYPE(doc->'$.medium'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.medium'),':',-1),JSON_TYPE(doc->'$.long'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.long'),':',-1),JSON_TYPE(doc->'$.varbinary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.varbinary'),':',-1),JSON_TYPE(doc->'$.binary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.binary'),':',-1),JSON_TYPE(doc->'$.bits'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.bits'),':',-1) FROM poc.jt_after_object ORDER BY id",
                "1\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8=\n2\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8="
            ),
            (
                "unchanged-object-scalar-values",
                "SET time_zone='+00:00'; SELECT id,JSON_TYPE(doc->'$.decimal'),JSON_UNQUOTE(doc->'$.decimal'),JSON_TYPE(doc->'$.date'),JSON_UNQUOTE(doc->'$.date'),JSON_TYPE(doc->'$.time'),JSON_UNQUOTE(doc->'$.time'),JSON_TYPE(doc->'$.datetime'),JSON_UNQUOTE(doc->'$.datetime'),JSON_TYPE(doc->'$.timestamp'),JSON_UNQUOTE(doc->'$.timestamp') FROM poc.jt_after_array WHERE id=2 ORDER BY id",
                "2\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456"
            ),
            (
                "unchanged-object-scalar-values-binary-payloads",
                "SELECT id,JSON_TYPE(doc->'$.tiny'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.tiny'),':',-1),JSON_TYPE(doc->'$.blob'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.blob'),':',-1),JSON_TYPE(doc->'$.medium'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.medium'),':',-1),JSON_TYPE(doc->'$.long'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.long'),':',-1),JSON_TYPE(doc->'$.varbinary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.varbinary'),':',-1),JSON_TYPE(doc->'$.binary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.binary'),':',-1),JSON_TYPE(doc->'$.bits'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.bits'),':',-1) FROM poc.jt_after_array WHERE id=2 ORDER BY id",
                "2\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8="
            ),
            (
                "zero-temporal-and-exact-array-scalars",
                "SELECT JSON_TYPE(doc->'$[0]'),JSON_UNQUOTE(doc->'$[0]'),JSON_TYPE(doc->'$[1]'),JSON_UNQUOTE(doc->'$[1]'),JSON_TYPE(doc->'$[2]'),JSON_UNQUOTE(doc->'$[2]'),JSON_TYPE(doc->'$[3]'),JSON_UNQUOTE(doc->'$[3]') FROM poc.jt_after_array WHERE id=1",
                "DATE\t0000-00-00\tDATETIME\t0000-00-00 00:00:00.000000\tUNSIGNED INTEGER\t18446744073709551615\tDECIMAL\t1.00"
            ),
            ("empty-final-table", "SELECT id FROM poc.matrix_typedjson ORDER BY id", ""),
        ] {
            let check = try check("typedjson", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (original, wrong) in [
                    ("SQL_NULL", "NULL"), ("UNSIGNED INTEGER", "INTEGER"), ("DECIMAL", "DOUBLE"),
                    ("TIMESTAMP", "DATETIME"), ("BLOB", "STRING"), ("BIT", "INTEGER"),
                    ("18446744073709551615", "18446744073709551616"), ("9007199254740993", "9007199254740992"),
                    ("65CC81", "C3A9"), (".123456", ".123455"), ("AP8AAA==", "AP8="), ("Af8=", "Af4="),
                ] where value.contains(original) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: original, with: wrong)], engine: engine,
                            role: "target"))
                }
            }
        }
    }

    func testCompleteTypedObjectsKeepEveryScalarAndBinaryPayload() throws {
        let plan = try plan("typedjson")
        let scalar = try check("typedjson", "object-scalar-values").check
        for path in ["decimal", "date", "time", "datetime", "timestamp"] {
            XCTAssertTrue(scalar.sql.contains("JSON_TYPE(doc->'$." + path + "')"))
            XCTAssertTrue(scalar.sql.contains("JSON_UNQUOTE(doc->'$." + path + "')"))
        }
        let binary = try check("typedjson", "object-scalar-values-binary-payloads").check
        for path in ["tiny", "blob", "medium", "long", "varbinary", "binary", "bits"] {
            XCTAssertTrue(binary.sql.contains("JSON_TYPE(doc->'$." + path + "')"))
            XCTAssertTrue(binary.sql.contains("SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$." + path + "'),':',-1)"))
        }
        XCTAssertTrue(plan.final.checks.contains { $0.id == "unchanged-object-scalar-values" })
        XCTAssertTrue(plan.final.checks.contains { $0.id == "unchanged-object-scalar-values-binary-payloads" })
    }

    func testJSONTypesDistinguishSQLNullJSONNullEmptyAndExactNumbers() throws {
        let types = try check("json", "inserted-document-types").check.expected
        XCTAssertTrue(types.contains("2\tNULL\t1"))
        XCTAssertTrue(types.contains("3\tSQL_NULL\tSQL_NULL"))
        XCTAssertTrue(types.contains("6\tOBJECT\t0"))
        let integer = try check("json", "exact-large-integer-array").check
        XCTAssertTrue(integer.sql.contains("JSON_UNQUOTE(doc->'$[0]')"))
        XCTAssertTrue(integer.expected.contains("9007199254740993"))
        XCTAssertTrue(integer.expected.contains("DOUBLE\t1.25"))
        let scalar = try check("typedjson", "object-scalar-values").check
        XCTAssertTrue(scalar.expected.contains("-12345678901234567890123456789012345.123456789012345678901234567890"))
        XCTAssertFalse(scalar.sql.contains(" AS DOUBLE"))
    }

    func testJSONPartialRetainsSourceEventValidationAndItsRunner() throws {
        let test = try fixture("jsonpartial")
        XCTAssertNil(test.workflow)
        XCTAssertEqual(test.phases.map(\.expectsJSONDiff), [false, true, true, false])
        XCTAssertNotNil(test.source84OnlyReason)
    }

    func testProgressRejectsWrongCountsGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("json", 16, 6, 34), ("typedjson", 14, 4, 18),
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
            let expected = ["json": 14, "typedjson": 16]
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
                "unicodeidentifiers", "encodings", "widestrings", "spatial", "json", "typedjson", "floatbounds",
                "zerofill",
                "fixedfloating",
                "floating", "bits", "fixed", "enumzero", "choices", "widechoices", "integers", "decimal", "temporal",
                "precision", "lob", "defaults", "floatingautofloat", "floatingautodouble", "floatingautofixedfloat",
                "floatingautounsigneddouble",
            ])
    }
}
