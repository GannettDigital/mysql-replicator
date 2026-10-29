import XCTest

@testable import ReplicatorLabCore

final class DDLFinalObservationsTests: XCTestCase {
    func testMultiTableRetainsRestartOperationsAndFinalResults() throws {
        let test = DDLCompatibilityCases.multiTableDDL
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 30)
        XCTAssertEqual(phases.count, 6)
        XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
        XCTAssertEqual(
            phases.filter { $0.steps[0].restartBefore }.map { $0.steps[0].sql },
            [
                "RENAME TABLE ddlcompat.t TO otherdb.moved",
                "RENAME TABLE otherdb.moved TO ddlcompat.spare,ddlcompat.u TO otherdb.moved,ddlcompat.spare TO ddlcompat.u",
                "DROP TABLE ddlcompat.u,otherdb.moved,otherdb.copy RESTRICT",
                "DROP TABLE IF EXISTS ddlcompat.u,otherdb.moved,otherdb.absent CASCADE",
                "INSERT INTO ddlcompat.u VALUES(4,4.25)",
            ])
        XCTAssertEqual(final.databases, ["ddlcompat", "otherdb"])
        XCTAssertEqual(
            Set(final.checks.map(\.id)),
            [
                "moved-table-encoding", "moved-row", "updated-moved-row", "swapped-integer-table",
                "swapped-text-table", "like-copy-row", "like-copy-empty", "dropped-destination-tables",
                "old-and-temporary-names-absent", "reused-name-row", "reused-name-definition",
            ])
        let expected = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        for check in final.checks {
            _ = try check.result(expected, engine: "MyISAM", role: "target")
        }
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.mt_swap_u,otherdb.mt_moved,otherdb.mt_updated,otherdb.mt_swap_moved,otherdb.mt_copy,otherdb.mt_empty_copy"
            ])
        XCTAssertTrue(test.steps.allSatisfy { $0.sqlTransactional == $0.sql && $0.transactions == 1 })
    }

    func testCompoundRenameRetainsRestartsAndReplayBaseline() throws {
        let test = DDLCompatibilityCases.alterTableRename
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 53)
        XCTAssertEqual(phases.count, 5)
        XCTAssertEqual(
            phases.filter { $0.steps[0].restartBefore }.map { $0.steps[0].sql },
            [
                "ALTER TABLE ddlcompat.parent RENAME TO otherdb.moved,CHANGE id new_id INT",
                "ALTER TABLE ddlcompat.child ADD note INT DEFAULT 3,RENAME AS otherdb.kid",
                "ALTER TABLE otherdb.moved RENAME otherdb.unused_name,MODIFY note VARCHAR(30),RENAME TO ddlcompat.parent",
                "ALTER TABLE ddlcompat.child RENAME AS ddlcompat.temporary_child",
            ])
        // Replay still stops after the original parent move, before its update.
        XCTAssertEqual(test.steps[5].sql, "ALTER TABLE ddlcompat.parent RENAME TO otherdb.moved,CHANGE id new_id INT")
        XCTAssertEqual(test.steps[6].sqlTransactional, "UPDATE otherdb.moved SET new_id=2,a=11 WHERE new_id=1")
        XCTAssertEqual(final.databases, ["ddlcompat", "otherdb"])
        XCTAssertEqual(final.checks.count, 9)
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.ar_move_child,otherdb.ar_child_kid,ddlcompat.ar_return_child,ddlcompat.ar_final_child,otherdb.ar_move_moved,otherdb.ar_child_moved,ddlcompat.ar_return_parent,ddlcompat.ar_final_parent"
            ])
        XCTAssertEqual(
            final.replayResetSQL,
            "SET sql_log_bin=0; SET FOREIGN_KEY_CHECKS=0; " + final.cleanup[0]
                + "; DROP DATABASE ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; SET FOREIGN_KEY_CHECKS=1"
        )
        XCTAssertFalse(final.replayResetSQL.contains("DROP DATABASE otherdb"))
        XCTAssertEqual(test.steps[16].sql, "DROP TABLE ddlcompat.child,ddlcompat.parent")
    }

    func testCrossSchemaRetainsOriginalDropAndBothCascadeBranches() throws {
        let test = DDLCompatibilityCases.crossSchemaRelationships
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 30)
        XCTAssertEqual(phases.count, 5)
        XCTAssertEqual(
            phases.filter { $0.steps[0].restartBefore }.map { $0.steps[0].sql },
            [
                "RENAME TABLE ddlcompat.parent TO otherdb.parent",
                "RENAME TABLE ddlcompat.child TO otherdb.moved_child",
                "RENAME TABLE otherdb.parent TO ddlcompat.parent,otherdb.moved_child TO ddlcompat.child",
                "DROP TABLE ddlcompat.child,ddlcompat.parent",
            ])
        XCTAssertEqual(final.databases, ["ddlcompat", "otherdb"])
        XCTAssertEqual(final.checks.count, 6)
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE otherdb.cs_move_child,otherdb.cs_update_child,ddlcompat.cs_return_child,otherdb.cs_move_parent,otherdb.cs_update_parent,ddlcompat.cs_return_parent"
            ])
        let cascade = try XCTUnwrap(final.checks.first { $0.id == "cascade-after-move" })
        _ = try cascade.result([cascade.id: "1\t20\t1\t1"], engine: "InnoDB", role: "source", transactional: false)
        _ = try cascade.result([cascade.id: "2\t10\t1\t2"], engine: "InnoDB", role: "target", transactional: true)
        XCTAssertThrowsError(
            try cascade.result([cascade.id: "1\t20\t1\t1"], engine: "InnoDB", role: "target", transactional: true))
        let metadata = try XCTUnwrap(final.checks.first { $0.id == "returned-foreign-key" })
        XCTAssertTrue(metadata.selectedCheck(transactional: false).sql.contains("COUNT(*)"))
        XCTAssertFalse(metadata.selectedCheck(transactional: true).sql.contains("COUNT(*)"))
        XCTAssertTrue(
            final.queries(transactional: true).contains {
                $0.name == metadata.id && $0.sql.contains(metadata.selectedCheck(transactional: true).sql)
            })
    }

    func testColumnRenamesRetainAlterPrefixesAndReplayStop() throws {
        let test = DDLCompatibilityCases.columnRenames
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 48)
        XCTAssertEqual(phases.count, 5)
        XCTAssertEqual(
            phases.filter { $0.steps[0].restartBefore }.map { $0.steps[0].sql },
            [
                "ALTER TABLE ddlcompat.t RENAME COLUMN a TO renamed,RENAME COLUMN legacy TO legacy_name,ADD c INT DEFAULT 7",
                "ALTER TABLE ddlcompat.t RENAME COLUMN b TO computed",
                "INSERT INTO ddlcompat.t(id) VALUES(3)",
                "ALTER TABLE ddlcompat.t RENAME COLUMN a TO legacy_name,RENAME COLUMN legacy_name TO a",
            ])
        XCTAssertEqual(test.steps[2].sql, phases[1].steps[0].sql)
        XCTAssertEqual(test.steps[10].sql, "DROP TABLE ddlcompat.t")
        // Each retained result must execute its entire dependent ALTER prefix.
        // CREATE LIKE after an ALTER would not verify the translation itself.
        let original = Array(test.steps.prefix(11)).map(\.sql)
        var start = 11
        for (table, count) in [
            ("cr_encoding", 4), ("cr_generated", 6), ("cr_copy", 8), ("cr_swap", 9), ("cr_updated", 10),
        ] {
            XCTAssertEqual(
                Array(test.steps[start..<start + count]).map(\.sql),
                original.prefix(count).map { $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table) })
            start += count
        }
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.cr_encoding,ddlcompat.cr_generated,ddlcompat.cr_copy,ddlcompat.cr_swap,ddlcompat.cr_updated"
            ])
        XCTAssertEqual(LabProfile.allCases.filter { test.profileExclusions[$0] == nil }, [.forward])
        XCTAssertTrue(test.steps.allSatisfy { $0.sqlTransactional == $0.sql && $0.transactions == 1 })
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(checks["latin1-value-after-default-charset-change"], "636166E9")
        XCTAssertEqual(checks["renamed-column-definition"], "seed\tkeep comment\tutf8mb4\tutf8mb4_bin\t30")
        XCTAssertEqual(checks["renamed-prefix-index"], "again\t8")
        XCTAssertEqual(
            checks["generated-column-and-multibyte-update"], "1\tE7B582E3828FE3828A\t2\t7\n2\t6E657874\t3\t7")
        XCTAssertEqual(checks["omitted-column-default-after-copy"], "seed\t636166E9\t4\t7")
        XCTAssertEqual(checks["swapped-column-defaults"], "seed\t636166E9")
        XCTAssertEqual(checks["update-after-column-swap"], "changed\t636166E9\t4\t7")
        XCTAssertEqual(checks.count, 9)
    }

    func testFinalObservationsCannotHideChecksOrDuplicateNames() throws {
        let check = DDLFinalObservations.Observation(id: "row", check: .init("SELECT v FROM t", "1"))
        let phase = DDLExecutionPhase(id: "write", steps: [.init("INSERT INTO t VALUES(1)")])
        let valid = DDLFinalObservations(checks: [check], databases: ["ddlcompat"], cleanup: [])
        try valid.validate([phase])
        XCTAssertThrowsError(try valid.validate([]))
        XCTAssertThrowsError(
            try valid.validate([
                .init(id: "hidden", steps: [.init("SELECT 1", [.init("SELECT 1", "1")])])
            ]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [check, check], databases: ["ddlcompat"], cleanup: []).validate([phase]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [], databases: ["ddlcompat"], cleanup: []).validate([phase]))
        XCTAssertThrowsError(
            try DDLFinalObservations(checks: [check], databases: ["ddlcompat", "ddlcompat"], cleanup: []).validate([
                phase
            ]))
    }

    func testFinalQueryMismatchIdentifiesAssertionAndRole() throws {
        let check = DDLFinalObservations.Observation(
            id: "moved-row", check: .init("SELECT id,n FROM otherdb.moved", "1\tchanged"))
        XCTAssertThrowsError(try check.result(["moved-row": "1\tfirst"], engine: "MyISAM", role: "target")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("moved-row/target"))
            XCTAssertTrue(message.contains("SELECT id,n FROM otherdb.moved"))
            XCTAssertTrue(message.contains("expected 1\tchanged"))
        }
        XCTAssertThrowsError(try check.result([:], engine: "MyISAM", role: "target"))
        let plan = DDLFinalObservations(checks: [check], databases: ["otherdb"], cleanup: [])
        XCTAssertEqual(plan.queries()[0].name, "moved-row")
        XCTAssertTrue(plan.queries()[0].preserveWhitespace)
        XCTAssertTrue(plan.queries()[0].sql.contains("SET NAMES utf8mb4"))
    }
}
