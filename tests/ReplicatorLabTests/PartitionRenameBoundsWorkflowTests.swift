import XCTest

@testable import ReplicatorLabCore

final class PartitionRenameBoundsWorkflowTests: XCTestCase {
    private func verify(
        _ test: DDLCompatibilityCases.Case, originalCount: Int, sizes: [Int], restarts: [Int], names: [String]
    ) throws -> DDLFinalObservations {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, sizes)
        XCTAssertEqual(test.steps.count, sizes.reduce(0, +))
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, restarts)
        XCTAssertTrue(test.nativeInnoDB)
        XCTAssertTrue(
            test.steps.allSatisfy {
                $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.checks.isEmpty && $0.assertionID == nil
            })
        var offset = originalCount
        for (index, name) in names.enumerated() {
            let length = index + 2
            let actual = Array(test.steps[offset..<offset + length])
            XCTAssertEqual(
                actual.map(\.sql),
                test.steps.prefix(length).map {
                    $0.sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + name)
                })
            XCTAssertTrue(actual.allSatisfy { !$0.restartBefore })
            offset += length
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(Set(names).isDisjoint(with: ["t", "s", "d", "encoded", "b"]))
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertEqual(final.cleanup, ["DROP TABLE " + names.map { "ddlcompat." + $0 }.joined(separator: ",")])
        XCTAssertTrue(final.replayResetSQL.contains(final.cleanup[0]))
        return final
    }

    private func check(_ final: DDLFinalObservations, _ id: String, _ sql: String, _ expected: String) throws {
        let observation = try XCTUnwrap(final.checks.first { $0.id == id })
        XCTAssertEqual(observation.check.sql, sql)
        XCTAssertEqual(observation.check.expected, expected)
        for engine in ["MyISAM", "InnoDB"] {
            _ = try observation.result([id: expected], engine: engine, role: "target")
            XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
        }
    }

    func testChangeColumnsRetainsSwapReferencesImplicitKeyAndDrop() throws {
        let test = DDLCompatibilityCases.partitionColumnRenames
        let final = try verify(
            test, originalCount: 13, sizes: [2, 2, 2, 2, 82], restarts: [3, 5, 7, 9],
            names: [
                "pc_seed", "pc_changed", "pc_moved", "pc_swapped", "pc_inserted", "pc_removed",
                "pc_implicit_key", "pc_key_renamed", "pc_updated", "pc_final_name", "pc_deleted",
            ])
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertEqual(
            test.steps[4].sql,
            "ALTER TABLE ddlcompat.t CHANGE x y INT,CHANGE y x INT PARTITION BY RANGE(y) SUBPARTITION BY HASH(x) SUBPARTITIONS 2 (PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)"
        )
        XCTAssertEqual(test.steps[7].sql, "ALTER TABLE ddlcompat.t PARTITION BY KEY() PARTITIONS 2")
        XCTAssertEqual(test.steps[12].sql, "DROP TABLE ddlcompat.t")
        try check(
            final, "changed-column-rows", "SELECT x,y,n FROM ddlcompat.pc_changed ORDER BY x", "1\t10\t100\n11\t20\t200"
        )
        try check(
            final, "moved-partition-rows", "SELECT x,y,n FROM ddlcompat.pc_moved PARTITION(p1) ORDER BY x",
            "11\t20\t200\n21\t30\t101")
        try check(
            final, "swapped-column-rows", "SELECT y,x,n FROM ddlcompat.pc_swapped ORDER BY y",
            "11\t20\t200\n21\t30\t101")
        try check(final, "insert-after-swap", "SELECT y,x,n FROM ddlcompat.pc_inserted PARTITION(p0)", "2\t3\t4")
        try check(
            final, "removed-partitions",
            "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='pc_removed' AND PARTITION_NAME IS NOT NULL",
            "0")
        try check(
            final, "renamed-key-rows", "SELECT key_id,sid,n FROM ddlcompat.pc_key_renamed ORDER BY key_id",
            "2\t3\t4\n11\t20\t200\n21\t30\t101")
        try check(
            final, "deleted-row-absent", "SELECT final_id,sid,n FROM ddlcompat.pc_deleted ORDER BY final_id",
            "11\t20\t201\n21\t30\t101")
        try check(
            final, "original-table-dropped",
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'", "0")
        for (id, expected) in [
            ("changed-partition-references", "RANGE\tx\tHASH\ty"),
            ("swapped-partition-references", "RANGE\ty\tHASH\tx"),
        ] {
            let observation = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertTrue(observation.check.sql.contains("SUBPARTITION_EXPRESSION"))
            XCTAssertEqual(observation.check.expected, expected)
        }
    }

    func testRenameColumnRetainsVersionExclusionsAndOriginalSyntax() throws {
        let test = DDLCompatibilityCases.partitionRenameSyntax
        let final = try verify(
            test, originalCount: 7, sizes: [2, 2, 23], restarts: [3, 5],
            names: [
                "ps_seed", "ps_renamed", "ps_moved", "ps_removed", "ps_deleted",
            ])
        XCTAssertEqual(
            test.profileExclusions,
            [
                .reverse: "MySQL 5.7 has no RENAME COLUMN syntax.",
                .mysql57MyISAM: "MySQL 5.7 has no RENAME COLUMN syntax.",
                .mysql57InnoDB: "MySQL 5.7 has no RENAME COLUMN syntax.",
            ])
        XCTAssertEqual(test.steps[4].sql, "ALTER TABLE ddlcompat.t RENAME COLUMN renamed TO id REMOVE PARTITIONING")
        XCTAssertEqual(test.steps[6].sql, "DROP TABLE ddlcompat.t")
        try check(
            final, "renamed-column-rows", "SELECT renamed,n FROM ddlcompat.ps_renamed ORDER BY renamed", "1\t10\n11\t20"
        )
        try check(
            final, "moved-partition-rows", "SELECT renamed,n FROM ddlcompat.ps_moved PARTITION(high) ORDER BY renamed",
            "11\t20\n21\t10")
        try check(final, "deleted-row-absent", "SELECT id,n FROM ddlcompat.ps_deleted", "21\t10")
        try check(
            final, "original-table-dropped",
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'", "0")
    }

    func testColumnBoundsRetainsExactBytesTupleRoutingAndLiteralWhitespace() throws {
        let test = DDLCompatibilityCases.partitionColumnBounds
        let final = try verify(
            test, originalCount: 13, sizes: [3, 5, 14], restarts: [4, 9],
            names: [
                "pb_seed", "pb_reorganized", "pb_moved",
            ])
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertTrue(test.steps[2].sql.contains("_binary X'F0'"))
        XCTAssertTrue(test.steps[4].sql.contains("_latin1 X'E9','a  '"))
        XCTAssertTrue(test.steps[6].sql.contains("'20260101',10"))
        try check(
            final, "binary-low-rows", "SELECT HEX(v),n FROM ddlcompat.pb_seed PARTITION(p) ORDER BY v",
            "0080\t1\n80FE\t2")
        try check(
            final, "binary-moved-rows", "SELECT HEX(v),n FROM ddlcompat.pb_moved PARTITION(middle) ORDER BY v",
            "80FF\t3\n81\t2")
        try check(
            final, "latin1-list-routing", "SELECT HEX(v),n FROM ddlcompat.s PARTITION(p) ORDER BY v", "61\t2\nE9\t1")
        try check(final, "tuple-below-bound", "SELECT id FROM ddlcompat.d PARTITION(p)", "9")
        try check(final, "tuple-at-bound", "SELECT id FROM ddlcompat.d PARTITION(q)", "10")
        try check(final, "final-binary-rows", "SELECT HEX(v),n FROM ddlcompat.t ORDER BY v", "0080\t1\n80FF\t3\n81\t2")
        try check(final, "connection-encoded-bytes", "SELECT HEX(v) FROM ddlcompat.encoded ORDER BY v", "C3A9\nE9")
        try check(
            final, "binary-literal-lengths", "SELECT LENGTH(v),HEX(v) FROM ddlcompat.b ORDER BY v",
            "0\t\n4\t005C0A27\n2\t2A2F\n1\tFF")
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
    }

    func testLatin1OverrideIsResetBeforeTheFollowingSourceOperation() throws {
        let test = DDLCompatibilityCases.partitionColumnBounds
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let writes = phases.flatMap { $0.writes(transactional: false) }
        XCTAssertEqual(
            test.steps[9].sql,
            "SET character_set_connection=latin1; CREATE TABLE ddlcompat.encoded(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN('é',_latin1 'é'))"
        )
        XCTAssertEqual(test.steps[9].sql.utf8.filter { $0 == 0xC3 }.count, 2)
        for profile in [LabProfile.forward, .reverse, .mysql57InnoDB, .mysql57MyISAM] {
            let queries = try LabSQLPhase.queries(
                Array(writes[9...10]), session: profile.session, status: profile.sourceVersion.binlogStatus)
            let sourceWrites = queries.filter { $0.name.hasSuffix("/warnings") }
            XCTAssertEqual(sourceWrites.count, 2)
            for query in sourceWrites {
                XCTAssertTrue(query.sql.hasPrefix("SET NAMES utf8mb4 COLLATE utf8mb4_bin;"))
                XCTAssertFalse(query.sql.contains("BEGIN"))
                XCTAssertFalse(query.sql.contains("COMMIT"))
            }
            let sql = sourceWrites[0].sql
            let reset = try XCTUnwrap(sql.range(of: "SET NAMES utf8mb4"))
            let override = try XCTUnwrap(sql.range(of: "SET character_set_connection=latin1"))
            let create = try XCTUnwrap(sql.range(of: "CREATE TABLE ddlcompat.encoded"))
            XCTAssertLessThan(reset.lowerBound, override.lowerBound)
            XCTAssertLessThan(override.lowerBound, create.lowerBound)
            XCTAssertFalse(sourceWrites[1].sql.contains("character_set_connection=latin1"))
            XCTAssertTrue(sourceWrites[1].sql.contains("INSERT INTO ddlcompat.encoded VALUES(X'E9'),(X'C3A9')"))
        }
    }
}
