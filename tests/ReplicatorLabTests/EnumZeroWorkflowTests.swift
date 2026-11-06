import Foundation
import XCTest

@testable import ReplicatorLabCore

final class EnumZeroWorkflowTests: XCTestCase {
    private var fixture: DMLCompatibilityCases.Case {
        DMLCompatibilityCases.cases.first { $0.id == "enumzero" }!
    }
    private let definition = "id ENUM('','one','two') PRIMARY KEY,e ENUM('','yes','no'),v INT UNSIGNED"
    private let originalSQL = [
        "SET SESSION sql_mode=''; INSERT INTO poc.matrix_enumzero VALUES(0,1,0),(1,0,1),(2,NULL,2)",
        "SET SESSION sql_mode=''; UPDATE poc.matrix_enumzero SET e=0,v=10 WHERE id+0=0; UPDATE poc.matrix_enumzero SET e=1,v=11 WHERE id+0=1",
        "DELETE FROM poc.matrix_enumzero WHERE id+0=0",
        "SET SESSION sql_mode=''; UPDATE poc.matrix_enumzero SET id=0,e=0,v=20 WHERE id+0=2",
    ]
    private let originalChecks = [
        "SELECT COUNT(*)=3 AND SUM(id+0=0)=1 AND SUM(id+0=1)=1 AND SUM(e+0=0)=1 AND SUM(e IS NULL)=1 FROM poc.matrix_enumzero",
        "SELECT COUNT(*)=1 FROM poc.matrix_enumzero WHERE id+0=0 AND e+0=0 AND v=10",
        "SELECT COUNT(*)=2 AND SUM(id+0=0)=0 FROM poc.matrix_enumzero",
        "SELECT COUNT(*)=1 FROM poc.matrix_enumzero WHERE id+0=0 AND e+0=0 AND v=20",
    ]
    private let tables = ["ez_after_insert", "ez_after_update", "ez_after_delete", "matrix_enumzero"]
    private let rowIDs = ["initial-rows", "updated-rows", "after-delete-rows", "final-rows"]
    private let rows = [
        "0\t\t1\t\t0\n1\t\t0\t\t1\n2\t6F6E65\tNULL\tNULL\t2",
        "0\t\t0\t\t10\n1\t\t1\t\t11\n2\t6F6E65\tNULL\tNULL\t2",
        "1\t\t1\t\t11\n2\t6F6E65\tNULL\tNULL\t2",
        "0\t\t0\t\t20\n1\t\t1\t\t11",
    ]

    func testOriginalDefinitionScriptsAndMetadataOwnershipRemain() throws {
        XCTAssertEqual(Data(fixture.definition.utf8), Data(definition.utf8))
        XCTAssertEqual(fixture.phases.map { Data($0.sql.utf8) }, originalSQL.map { Data($0.utf8) })
        XCTAssertEqual(fixture.phases.map(\.check), originalChecks)
        XCTAssertEqual(fixture.orderBy, "id+0")
        XCTAssertEqual(fixture.rowMetadata, "FULL")
        XCTAssertTrue(fixture.setup.isEmpty)
        XCTAssertNil(fixture.replicatedReplacement)
        XCTAssertEqual(MetadataDiscoveryCases.representative("enumzero"), "exactchoices")
        XCTAssertEqual(MetadataDiscoveryCases.owner("enumzero"), MetadataDiscoveryCases.encodings.id)
        for profile in LabProfile.allCases {
            XCTAssertTrue(fixture.applies(to: profile))
            let cold = MetadataDiscoveryCases.fixtures(MetadataDiscoveryCases.encodings.id, profile: profile)
            XCTAssertFalse(cold.contains { $0.id == "enumzero" })
            let representative = try XCTUnwrap(cold.first { $0.id == "exactchoices" })
            XCTAssertEqual(representative.phases.count, 4)
            XCTAssertEqual(representative.rowMetadata, "FULL")
        }
    }

    func testBatchesKeepOriginalScriptsAndSourceTransactionCounts() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        XCTAssertEqual(
            plan.prepare.writes.map(\.sql),
            (["matrix_enumzero"] + tables.dropLast()).map {
                "CREATE TABLE poc." + $0 + "(" + definition + ") DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            })
        var expected = originalSQL.map { "USE poc; " + $0 }
        for (length, table) in tables.dropLast().enumerated() {
            expected += originalSQL.prefix(length + 1).map {
                "USE poc; " + $0.replacingOccurrences(of: "poc.matrix_enumzero", with: "poc." + table)
            }
        }
        XCTAssertEqual(plan.body.writes.map { Data($0.sql.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.prepare.transactionCount, 4)
        XCTAssertEqual(plan.body.transactions, [1, 2, 1, 1, 1, 1, 2, 1, 2, 1])
        XCTAssertEqual(plan.body.transactionCount, 13)
        XCTAssertEqual(plan.cleanup.transactionCount, 1)
        XCTAssertEqual(plan.expectedDDL, 4)
        XCTAssertEqual(plan.expectedRows, 21)
        XCTAssertFalse(plan.body.writes.contains { $0.sql.contains("BEGIN") || $0.sql.contains("COMMIT") })
    }

    func testNonStrictModeStaysInsideEachWriteAfterTheSessionReset() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for profile in LabProfile.allCases {
            for batch in [plan.prepare, plan.body, plan.cleanup] {
                let queries = try LabSQLPhase.queries(
                    batch.writes, session: profile.session, status: profile.sourceVersion.binlogStatus)
                for (index, write) in batch.writes.enumerated() {
                    let query = queries[index * 4]
                    XCTAssertTrue(query.sql.hasPrefix(profile.session + "\n"))
                    XCTAssertTrue(query.sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                    XCTAssertTrue(query.preserveWhitespace)
                    XCTAssertFalse(write.checkWarnings)
                    let usesNonStrictMode = write.sql.contains("SET SESSION sql_mode=''")
                    let modifiesZero = write.sql.contains("INSERT INTO") || write.sql.contains("UPDATE")
                    XCTAssertEqual(usesNonStrictMode, modifiesZero)
                    if usesNonStrictMode {
                        XCTAssertTrue(write.sql.hasPrefix("USE poc; SET SESSION sql_mode=''; "))
                    }
                }
            }
        }
        // Ordinal-zero writes can produce warnings. Retain them without rejecting the request.
        let write = plan.body.writes[0]
        let start = Boundary(file: "binlog.000001", position: 100, gtids: "uuid:1")
        let decoded = try LabSQLPhase.decode(
            [write], start: start,
            values: [
                write.id + "/warnings": "Warning\t1265\tData truncated for column 'id' at row 1",
                write.id + "/delta": "uuid:2",
                write.id + "/position": "binlog.000001\t200",
                write.id + "/gtids": "uuid:1-2",
            ])
        XCTAssertEqual(decoded.first?.warnings, "Warning\t1265\tData truncated for column 'id' at row 1")
    }

    func testAllOriginalPredicatesRemainOnTheirMatchingResults() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for index in originalChecks.indices {
            let check = plan.final.checks[index]
            XCTAssertEqual(
                check.check.sql,
                originalChecks[index].replacingOccurrences(of: "poc.matrix_enumzero", with: "poc." + tables[index]))
            XCTAssertEqual(check.check.expected, "1")
            _ = try check.result([check.id: "1"], engine: "MyISAM", role: "target")
            XCTAssertThrowsError(try check.result([check.id: "0"], engine: "MyISAM", role: "target"))
        }
    }

    func testCompleteRowsDistinguishZeroEmptyAndNullBeforeAndAfterKeyReuse() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        for index in rows.indices {
            let check = try XCTUnwrap(plan.final.checks.first { $0.id == rowIDs[index] })
            XCTAssertEqual(
                check.check.sql,
                "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),v FROM poc." + tables[index]
                    + " ORDER BY id+0")
            XCTAssertEqual(Data(check.check.expected.utf8), Data(rows[index].utf8))
            XCTAssertTrue(
                rows[index].split(separator: "\n").allSatisfy {
                    $0.split(separator: "\t", omittingEmptySubsequences: false).count == 5
                })
            for engine in ["InnoDB", "MyISAM"] {
                _ = try check.result([check.id: rows[index]], engine: engine, role: "target")
                var wrong = rows[index].replacingOccurrences(of: "\t\t", with: "\t")
                XCTAssertThrowsError(try check.result([check.id: wrong], engine: engine, role: "target"))
                wrong = rows[index].replacingOccurrences(of: "1\t\t1\t\t11", with: "1\t\t0\t\t11")
                if index > 0 {
                    XCTAssertThrowsError(try check.result([check.id: wrong], engine: engine, role: "target"))
                }
                if index < 3 {
                    wrong = rows[index].replacingOccurrences(of: "NULL", with: "")
                    XCTAssertThrowsError(try check.result([check.id: wrong], engine: engine, role: "target"))
                }
            }
        }
        let initial = try XCTUnwrap(plan.final.checks.first { $0.id == "initial-rows" })
        let wrongKey = rows[0].replacingOccurrences(of: "0\t\t1\t\t0", with: "1\t\t1\t\t0")
        XCTAssertThrowsError(try initial.result([initial.id: wrongKey], engine: "MyISAM", role: "target"))
        let final = try XCTUnwrap(plan.final.checks.first { $0.id == "final-rows" })
        XCTAssertThrowsError(try final.result([final.id: rows[2]], engine: "MyISAM", role: "target"))
        XCTAssertTrue(plan.final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testCheckpointsRequireExactCountersGTIDsAndOffsets() throws {
        let plan = try XCTUnwrap(fixture.workflow).plan(fixture)
        let before: [String: Any] = ["transactionsApplied": 2, "ddlApplied": 1, "rowsApplied": 3]
        let end = Boundary(file: "binlog.000001", position: 3000, gtids: "uuid:1-19")
        var after: [String: Any] = [
            "transactionsApplied": 19, "ddlApplied": 5, "rowsApplied": 24, "appliedGTIDSet": end.gtids,
            "appliedPosition": ["file": end.file, "position": "3000"],
        ]
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 16
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["transactionsApplied"] = 19
        after["appliedPosition"] = ["file": end.file, "position": "2999"]
        XCTAssertThrowsError(try plan.validateProgress(before: before, after: after, end: end, cleaned: false))
        after["appliedPosition"] = ["file": end.file, "position": "3000"]
        after["transactionsApplied"] = 20
        after["ddlApplied"] = 6
        let cleaned = Boundary(file: end.file, position: 3000, gtids: "uuid:1-20")
        after["appliedGTIDSet"] = cleaned.gtids
        XCTAssertNoThrow(try plan.validateProgress(before: before, after: after, end: cleaned, cleaned: true))
    }

    func testCleanupTitleAndExplicitOrderKeepTheOtherChoiceCases() throws {
        let workflow = try XCTUnwrap(fixture.workflow)
        let plan = try workflow.plan(fixture)
        XCTAssertEqual(workflow.order, .idOrdinal)
        XCTAssertEqual(plan.final.checks.count, 8)
        XCTAssertEqual(plan.final.databases, ["poc"])
        XCTAssertEqual(
            plan.cleanup.writes.map(\.sql), ["DROP TABLE poc.ez_after_insert,poc.ez_after_update,poc.ez_after_delete"])
        XCTAssertEqual(plan.final.cleanup, plan.cleanup.writes.map(\.sql))
        XCTAssertEqual(fixture.displayName, "ENUM: ordinal zero, empty members and primary-key changes")
        XCTAssertEqual(LabScenario.correctness.first { $0.id == "matrix-enumzero" }?.test.name, fixture.displayName)
        XCTAssertEqual(
            DMLCompatibilityCases.replicatedCases.filter { $0.workflow != nil }.map(\.id),
            [
                "collations", "nativeencodings", "exactchoices", "choiceboundaries", "binarychoices", "legacybinaryset",
                "decimaldefaults", "zerowidth", "identifiercase", "unicodeidentifiers", "encodings", "widestrings",
                "bits", "enumzero", "choices", "widechoices", "integers", "decimal",
            ])
    }
}
