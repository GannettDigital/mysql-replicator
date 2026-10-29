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

    func testTableOptionsRetainOriginalIDsAndDefinitions() throws {
        let test = DDLCompatibilityCases.tableOptions
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 16)
        XCTAssertEqual(phases.count, 3)
        XCTAssertEqual(
            test.steps.filter(\.restartBefore).map(\.sql),
            [
                "ALTER TABLE ddlcompat.t COMMENT='changed note' ROW_FORMAT=DYNAMIC, AUTO_INCREMENT=200",
                "INSERT INTO ddlcompat.copy(id,n) VALUES(1,'copy')",
            ])
        let original = test.steps.prefix(9).map(\.sql)
        XCTAssertEqual(
            test.steps[9..<11].map(\.sql),
            original.prefix(2).map {
                $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat.to_initial")
            })
        XCTAssertEqual(
            test.steps[11..<16].map(\.sql),
            original.prefix(5).map {
                $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat.to_changed")
            })
        let checks = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(checks["initial-generated-id-and-binary-default"], "100\tfirst\t00FF")
        XCTAssertEqual(checks["generated-ids-before-update-delete"], "100\tfirst\t00FF\n200\tsecond\t00FF")
        XCTAssertEqual(checks["changed-column-definition"], "changed column\t40\tYES\t1")
        XCTAssertEqual(checks["update-and-delete"], "100\tlast\t00FF")
        XCTAssertEqual(checks.count, 10)
    }

    func testMaintenanceRetainsDisabledEnabledAndRebuiltTables() throws {
        let test = DDLCompatibilityCases.tableMaintenance
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 31)
        XCTAssertEqual(phases.count, 4)
        XCTAssertEqual(
            test.steps.filter(\.restartBefore).map(\.sql),
            [
                "INSERT INTO ddlcompat.t(id,v) VALUES(3,30)",
                "ALTER TABLE ddlcompat.t FORCE", "DELETE FROM ddlcompat.t WHERE id=3",
            ])
        let original = test.steps.prefix(10).map(\.sql)
        var start = 10
        for (name, count) in [("tm_disabled", 6), ("tm_enabled", 7), ("tm_rebuilt", 8)] {
            XCTAssertEqual(
                test.steps[start..<start + count].map(\.sql),
                original.prefix(count).map {
                    $0.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + name)
                })
            start += count
        }
        // A rebuild of the enabled table could hide a failed ENABLE KEYS.
        XCTAssertFalse(test.steps.contains { $0.sql == "ALTER TABLE ddlcompat.tm_enabled FORCE" })
        let disabled = try XCTUnwrap(final.checks.first { $0.id == "disabled-nonunique-index" })
        let fields = ["tm_disabled", "1", "by_v", "1", "v", "A", "2", "NULL", "NULL", "YES", "BTREE", "disabled", ""]
        _ = try disabled.result([disabled.id: fields.joined(separator: "\t")], engine: "MyISAM", role: "target")
        var innodb = fields
        innodb[11] = ""
        _ = try disabled.result([disabled.id: innodb.joined(separator: "\t")], engine: "InnoDB", role: "source")
        XCTAssertThrowsError(
            try disabled.result([disabled.id: innodb.joined(separator: "\t")], engine: "MyISAM", role: "target"))
        XCTAssertEqual(final.checks.count, 6)
    }

    func testAlterOptionsPreserveEngineBranchesAndReplayStop() throws {
        let test = DDLCompatibilityCases.remainingAlterOptions
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 17)
        XCTAssertEqual(phases.count, 3)
        // Replay transaction three is still the original ORDER BY operation.
        XCTAssertEqual(test.steps[2].sql, "ALTER TABLE ddlcompat.t COMMENT='ordered',ORDER BY n DESC,id ASC")
        XCTAssertEqual(test.steps.filter(\.restartBefore).map(\.sql), [test.steps[2].sql, test.steps[4].sql])
        XCTAssertEqual(test.steps[6].sql, "DROP TABLE ddlcompat.t")
        let original = Array(test.steps.prefix(7))
        var start = 7
        for (table, count) in [("ao_validated", 4), ("ao_updated", 6)] {
            for (offset, step) in test.steps[start..<start + count].enumerated() {
                XCTAssertEqual(
                    step.sql, original[offset].sql.replacingOccurrences(of: "ddlcompat.t", with: "ddlcompat." + table))
                XCTAssertEqual(
                    step.sqlTransactional,
                    original[offset].sqlTransactional.replacingOccurrences(
                        of: "ddlcompat.t", with: "ddlcompat." + table))
            }
            start += count
        }
        for step in test.steps where step.sql.hasPrefix("CREATE TABLE") {
            XCTAssertFalse(step.sql.contains("COMPRESSION="))
            XCTAssertTrue(step.sqlTransactional.contains("COMPRESSION='none' ENCRYPTION='N'"))
        }
        let values = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(values["with-validation-values"], "1\t10\t11\n2\t20\t21")
        XCTAssertEqual(values["without-validation-and-update"], "1\t30\t32\n2\t20\t22")
        XCTAssertEqual(values["original-table-dropped"], "0")
        XCTAssertEqual(final.cleanup, ["DROP TABLE ddlcompat.ao_validated,ddlcompat.ao_updated"])
        XCTAssertTrue(
            final.replayResetSQL.hasPrefix(
                "SET sql_log_bin=0; SET FOREIGN_KEY_CHECKS=0; DROP TABLE ddlcompat.ao_validated"))
    }

    func testIgnoredChecksRetainViolatingRowsAndReplayBoundary() throws {
        let test = DDLCompatibilityCases.ignoredChecks
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, 12)
        XCTAssertEqual(phases.count, 3)
        XCTAssertEqual(
            test.steps[2].sql, "ALTER TABLE ddlcompat.t ADD CONSTRAINT never_check CHECK(v>100), ADD CHECK(v<0)")
        XCTAssertEqual(
            test.steps.filter(\.restartBefore).map(\.sql),
            [
                "INSERT INTO ddlcompat.t VALUES(-2,-2)", "UPDATE ddlcompat.t SET v=-999 WHERE id=1",
            ])
        XCTAssertEqual(test.steps.last?.sql, "DELETE FROM ddlcompat.t WHERE id=-1")
        XCTAssertEqual(Set(test.profileExclusions.keys), [.forward])
        XCTAssertTrue(test.steps.allSatisfy { $0.sql == $0.sqlTransactional })
        XCTAssertTrue(final.cleanup.isEmpty)
        let values = Dictionary(uniqueKeysWithValues: final.checks.map { ($0.id, $0.check.expected) })
        XCTAssertEqual(values["violating-rows-after-update-delete"], "-3\t-3\t7\n-2\t-2\t7\n1\t-999\t7")
        // The copy retains the row deleted from the original table.
        XCTAssertEqual(values["like-copy-before-delete"], "-3\t-3\n-2\t-2\n-1\t-1\n1\t-999")
        XCTAssertEqual(values["no-check-constraints"], "0")
        let check = try XCTUnwrap(final.checks.first { $0.id == "no-check-constraints" })
        XCTAssertThrowsError(try check.result([check.id: "1"], engine: "InnoDB", role: "target"))
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
