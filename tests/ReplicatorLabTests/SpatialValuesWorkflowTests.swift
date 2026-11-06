import Foundation
import XCTest

@testable import ReplicatorLabCore

final class SpatialValuesWorkflowTests: XCTestCase {
    private struct Original {
        let id: String
        let definition: String
        let sql: [String]
        let predicates: [String]
    }
    private let originals: [Original] = [
        .init(
            id: "spatial",
            definition:
                "id INT PRIMARY KEY,g GEOMETRY,p POINT NOT NULL,l LINESTRING,poly POLYGON,mp MULTIPOINT,ml MULTILINESTRING,mpl MULTIPOLYGON,gc GEOMETRYCOLLECTION,SPATIAL INDEX sp(p)",
            sql: [
                "INSERT INTO poc.matrix_spatial VALUES(1,ST_GeomFromText('POINT(1 2)'),ST_GeomFromText('POINT(3 4)'),ST_GeomFromText('LINESTRING(0 0,1 1)'),ST_GeomFromText('POLYGON((0 0,0 2,2 2,2 0,0 0))'),ST_GeomFromText('MULTIPOINT(0 0,1 2)'),ST_GeomFromText('MULTILINESTRING((0 0,1 1),(2 2,3 3))'),ST_GeomFromText('MULTIPOLYGON(((0 0,0 2,2 2,2 0,0 0)))'),ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(0 0,1 1))')),(2,NULL,ST_GeomFromText('POINT(3 4)',4326),NULL,NULL,NULL,NULL,NULL,GeometryCollection())",
                "UPDATE poc.matrix_spatial SET id=10,g=ST_GeomFromText('GEOMETRYCOLLECTION(POINT(5 6))'),l=ST_GeomFromText('LINESTRING(-1 -2,3 4)'),gc=GeometryCollection() WHERE id=1",
                "ALTER TABLE poc.matrix_spatial ADD extra GEOMETRYCOLLECTION; DROP INDEX sp ON poc.matrix_spatial; CREATE SPATIAL INDEX sp2 ON poc.matrix_spatial(p); UPDATE poc.matrix_spatial SET extra=ST_GeomFromText('GEOMETRYCOLLECTION(POINT(7 8))') WHERE id=10",
                "DELETE FROM poc.matrix_spatial WHERE id=10",
            ],
            predicates: [
                "SELECT COUNT(*)=2 AND SUM(g IS NULL)=1 AND SUM(ST_SRID(p)=4326)=1 AND SUM(ST_NumGeometries(gc)=0)=1 FROM poc.matrix_spatial",
                "SELECT COUNT(*)=1 FROM poc.matrix_spatial WHERE id=10 AND ST_NumGeometries(g)=1 AND ST_NumGeometries(gc)=0",
                "SELECT COUNT(*)=1 FROM poc.matrix_spatial WHERE id=10 AND ST_NumGeometries(extra)=1",
                "SELECT COUNT(*)=1 AND SUM(id=2)=1 AND SUM(g IS NULL)=1 FROM poc.matrix_spatial",
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
        [(originals[0], ["sv_after_insert", "sv_after_key_update", "sv_after_indexes"], [1, 1, 4, 1])]
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

    func testFixedGeometryRowsMetadataAndIndexesRejectChanges() throws {
        for (name, sql, value) in [
            (
                "inserted-geometry-bytes",
                "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL') FROM poc.sv_after_insert ORDER BY id",
                "1\t000000000101000000000000000000F03F0000000000000040\t0000000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000107000000020000000101000000000000000000F03F000000000000004001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F\n2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000"
            ),
            (
                "point-srids-and-coordinates-1",
                "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_insert ORDER BY id",
                "1\t0\tPOINT\t25\t3\t4\n2\t4326\tPOINT\t25\t3\t4"
            ),
            (
                "cartesian-point-bytes-1", "SELECT id,HEX(p) FROM poc.sv_after_insert WHERE ST_SRID(p)=0 ORDER BY id",
                "1\t00000000010100000000000000000008400000000000001040"
            ),
            (
                "spatial-index-1",
                "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_insert' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                "sp\tSPATIAL\t1\t1\tp\t32"
            ),
            (
                "declared-geometry-types-1",
                "SELECT COLUMN_NAME,CASE WHEN DATA_TYPE='geomcollection' THEN 'geometrycollection' ELSE DATA_TYPE END,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_insert' ORDER BY ORDINAL_POSITION",
                "id\tint\tNO\ng\tgeometry\tYES\np\tpoint\tNO\nl\tlinestring\tYES\npoly\tpolygon\tYES\nmp\tmultipoint\tYES\nml\tmultilinestring\tYES\nmpl\tmultipolygon\tYES\ngc\tgeometrycollection\tYES"
            ),
            (
                "key-update-geometry-bytes",
                "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL') FROM poc.sv_after_key_update ORDER BY id",
                "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\n10\t00000000010700000001000000010100000000000000000014400000000000001840\t00000000010200000002000000000000000000F0BF00000000000000C000000000000008400000000000001040\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t00000000010700000000000000"
            ),
            (
                "point-srids-and-coordinates-2",
                "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_key_update ORDER BY id",
                "2\t4326\tPOINT\t25\t3\t4\n10\t0\tPOINT\t25\t3\t4"
            ),
            (
                "cartesian-point-bytes-2",
                "SELECT id,HEX(p) FROM poc.sv_after_key_update WHERE ST_SRID(p)=0 ORDER BY id",
                "10\t00000000010100000000000000000008400000000000001040"
            ),
            (
                "spatial-index-2",
                "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_key_update' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                "sp\tSPATIAL\t1\t1\tp\t32"
            ),
            (
                "added-column-geometry-bytes",
                "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.sv_after_indexes ORDER BY id",
                "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\tNULL\n10\t00000000010700000001000000010100000000000000000014400000000000001840\t00000000010200000002000000000000000000F0BF00000000000000C000000000000008400000000000001040\t00000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t000000000104000000020000000101000000000000000000000000000000000000000101000000000000000000F03F0000000000000040\t0000000001050000000200000001020000000200000000000000000000000000000000000000000000000000F03F000000000000F03F0102000000020000000000000000000040000000000000004000000000000008400000000000000840\t00000000010600000001000000010300000001000000050000000000000000000000000000000000000000000000000000000000000000000040000000000000004000000000000000400000000000000040000000000000000000000000000000000000000000000000\t00000000010700000000000000\t0000000001070000000100000001010000000000000000001C400000000000002040"
            ),
            (
                "point-srids-and-coordinates-3",
                "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.sv_after_indexes ORDER BY id",
                "2\t4326\tPOINT\t25\t3\t4\n10\t0\tPOINT\t25\t3\t4"
            ),
            (
                "cartesian-point-bytes-3", "SELECT id,HEX(p) FROM poc.sv_after_indexes WHERE ST_SRID(p)=0 ORDER BY id",
                "10\t00000000010100000000000000000008400000000000001040"
            ),
            (
                "spatial-index-3",
                "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_indexes' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                "sp2\tSPATIAL\t1\t1\tp\t32"
            ),
            (
                "declared-geometry-types-3",
                "SELECT COLUMN_NAME,CASE WHEN DATA_TYPE='geomcollection' THEN 'geometrycollection' ELSE DATA_TYPE END,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='sv_after_indexes' ORDER BY ORDINAL_POSITION",
                "id\tint\tNO\ng\tgeometry\tYES\np\tpoint\tNO\nl\tlinestring\tYES\npoly\tpolygon\tYES\nmp\tmultipoint\tYES\nml\tmultilinestring\tYES\nmpl\tmultipolygon\tYES\ngc\tgeometrycollection\tYES\nextra\tgeometrycollection\tYES"
            ),
            (
                "remaining-null-and-empty-row",
                "SELECT id,IFNULL(HEX(g),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(poly),'NULL'),IFNULL(HEX(mp),'NULL'),IFNULL(HEX(ml),'NULL'),IFNULL(HEX(mpl),'NULL'),IFNULL(HEX(gc),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_spatial ORDER BY id",
                "2\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t00000000010700000000000000\tNULL"
            ),
            (
                "point-srids-and-coordinates-4",
                "SELECT id,ST_SRID(p),ST_GeometryType(p),OCTET_LENGTH(p),LEAST(ST_X(p),ST_Y(p)),GREATEST(ST_X(p),ST_Y(p)) FROM poc.matrix_spatial ORDER BY id",
                "2\t4326\tPOINT\t25\t3\t4"
            ),
            ("cartesian-point-bytes-4", "SELECT id,HEX(p) FROM poc.matrix_spatial WHERE ST_SRID(p)=0 ORDER BY id", ""),
            (
                "spatial-index-4",
                "SELECT INDEX_NAME,INDEX_TYPE,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,'NULL') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_spatial' AND INDEX_NAME<>'PRIMARY' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                "sp2\tSPATIAL\t1\t1\tp\t32"
            ),
        ] {
            let check = try check("spatial", name)
            XCTAssertEqual(check.check.sql, sql)
            XCTAssertEqual(Data(check.check.expected.utf8), Data(value.utf8))
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([name: value], engine: engine, role: "target")
                XCTAssertThrowsError(try check.result([name: value + "\n1"], engine: engine, role: "target"))
                for (old, wrong) in [
                    ("NULL", ""), ("4326", "0"), ("SPATIAL", "BTREE"), ("sp2", "sp"), ("\tp\t32", "\tp\t16"),
                    ("geometrycollection", "geometry"), ("00000000010700000000000000", "NULL"),
                    ("000000000000F03F", "0000000000000040"),
                ] where value.contains(old) {
                    XCTAssertThrowsError(
                        try check.result(
                            [name: value.replacingOccurrences(of: old, with: wrong)], engine: engine, role: "target"))
                }
            }
        }
    }

    func testStoredBytesKeepWKBTypesStructureAndNegativeCoordinates() throws {
        func bytes(_ value: String) throws -> [UInt8] {
            let chars = Array(value)
            return try stride(from: 0, to: chars.count, by: 2).map {
                try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
            }
        }
        func uint(_ b: [UInt8], _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[offset + $1]) << (8 * $1) }
        }
        let rows = try check("spatial", "inserted-geometry-bytes").check.expected.components(separatedBy: "\n")
        let first = try XCTUnwrap(rows.first).components(separatedBy: "\t")
        XCTAssertEqual(first.count, 8)
        let types: [UInt32] = [1, 2, 3, 4, 5, 6, 7]
        let sizes = [25, 45, 97, 55, 95, 106, 75]
        for (i, hex) in first.dropFirst().enumerated() {
            let raw = try bytes(hex)
            XCTAssertEqual(Array(raw.prefix(4)), [0, 0, 0, 0])
            XCTAssertEqual(raw[4], 1)
            XCTAssertEqual(uint(raw, 5), types[i])
            XCTAssertEqual(raw.count, sizes[i])
            if i > 0 { XCTAssertEqual(uint(raw, 9), [2, 1, 2, 2, 1, 2][i - 1]) }
        }
        let nullRow = try XCTUnwrap(rows.last).components(separatedBy: "\t")
        XCTAssertEqual(Array(nullRow[1...6]), Array(repeating: "NULL", count: 6))
        XCTAssertEqual(nullRow[7], "00000000010700000000000000")
        let changed = try check("spatial", "key-update-geometry-bytes").check.expected
        XCTAssertTrue(changed.contains("000000000000F0BF00000000000000C0"))
        XCTAssertTrue(changed.contains("10\t00000000010700000001000000"))
    }

    func testPointSRIDsAndCoordinatesKeepGeographicOrderInNativeComparison() throws {
        for stage in 1...4 {
            let point = try check("spatial", "point-srids-and-coordinates-" + String(stage)).check
            XCTAssertTrue(point.expected.contains("2\t4326\tPOINT\t25\t3\t4"))
            XCTAssertTrue(point.sql.contains("ST_SRID(p)"))
            XCTAssertTrue(point.sql.contains("LEAST(ST_X(p),ST_Y(p))"))
            XCTAssertTrue(point.sql.contains("GREATEST(ST_X(p),ST_Y(p))"))
            XCTAssertFalse(point.sql.contains("ST_AsText"))
            let raw = try check("spatial", "cartesian-point-bytes-" + String(stage)).check
            XCTAssertTrue(raw.sql.contains("WHERE ST_SRID(p)=0"))
            if stage < 4 {
                XCTAssertTrue(raw.expected.contains("00000000010100000000000000000008400000000000001040"))
            } else {
                XCTAssertEqual(raw.expected, "")
            }
        }
        XCTAssertEqual(try plan("spatial").final.databases, ["poc"])
    }

    func testIndexChangeAndAddedCollectionKeepTheirEarlierResults() throws {
        for stage in 1...4 {
            let value = try check("spatial", "spatial-index-" + String(stage)).check.expected
            XCTAssertEqual(value, (stage < 3 ? "sp" : "sp2") + "\tSPATIAL\t1\t1\tp\t32")
        }
        let declared = try check("spatial", "declared-geometry-types-1").check.expected
        XCTAssertTrue(declared.contains("p\tpoint\tNO"))
        XCTAssertTrue(declared.contains("gc\tgeometrycollection\tYES"))
        XCTAssertFalse(declared.contains("extra"))
        XCTAssertTrue(
            try check("spatial", "declared-geometry-types-3").check.expected.hasSuffix("extra\tgeometrycollection\tYES")
        )
        let writes = try plan("spatial").body.writes
        XCTAssertEqual(writes.filter { $0.sql.contains("DROP INDEX sp ON") }.count, 2)
        XCTAssertEqual(writes.filter { $0.sql.contains("CREATE SPATIAL INDEX sp2") }.count, 2)
    }

    func testProgressRejectsWrongCountsGTIDSetsAndOffsets() throws {
        for (id, transactions, ddl, rows) in [
            ("spatial", 20, 10, 14)
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
            let expected = ["spatial": 22]
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
