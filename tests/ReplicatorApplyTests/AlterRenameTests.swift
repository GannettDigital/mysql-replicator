import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

final class AlterRenameTests: XCTestCase {
    func testRenameSlicesAcceptNativePartitionComments() throws {
        let sql =
            "CREATE TABLE `t` (`id` int NOT NULL,`note` varchar(40) DEFAULT '/*!50100 keep */',PRIMARY KEY (`id`)) /*!50100 PARTITION BY HASH (`id`) PARTITIONS 2 */"
        let bytes = Data(sql.utf8)
        let slices = try TargetSession.renameColumnSlices(bytes, sqlMode: 0)
        XCTAssertEqual(slices.map(\.name), ["id", "note"])
        XCTAssertEqual(String(decoding: bytes[slices[0].definition], as: UTF8.self), " int NOT NULL")
        XCTAssertEqual(
            String(decoding: bytes[slices[1].definition], as: UTF8.self), " varchar(40) DEFAULT '/*!50100 keep */'")
        XCTAssertNoThrow(try parse(sql))
    }

    func testRenameEncodingPrecedesNativeAttributes() throws {
        var c = ApplyColumn(name: "a", type: "varchar(30)", nullable: true, collation: "utf8mb4_bin")
        c.characterSet = "utf8mb4"
        XCTAssertEqual(
            try TargetSession.renameColumnDefinition(
                " varchar(30) COLLATE utf8mb4_bin DEFAULT 'seed' COMMENT 'keep'", column: c, sqlMode: 0),
            " varchar(30) CHARACTER SET `utf8mb4` COLLATE utf8mb4_bin DEFAULT 'seed' COMMENT 'keep'")
        XCTAssertEqual(
            try TargetSession.renameColumnDefinition(" enum('a,b','c') DEFAULT 'c'", column: c, sqlMode: 0),
            " enum('a,b','c') CHARACTER SET `utf8mb4` COLLATE `utf8mb4_bin` DEFAULT 'c'")
        c.characterSet = "latin1"
        c.collation = "latin1_swedish_ci"
        XCTAssertEqual(
            try TargetSession.renameColumnDefinition(
                " varchar(20) CHARACTER SET latin1 DEFAULT NULL", column: c, sqlMode: 0),
            " varchar(20) CHARACTER SET latin1 COLLATE `latin1_swedish_ci` DEFAULT NULL")
    }

    func query(_ sql: String) -> QueryControl {
        .init(database: "poc", sql: Data(sql.utf8), errorCode: 0, statusVariables: Data())
    }
    func parse(_ sql: String) throws -> DDLStatement { try .parse(query(sql), profile: .mysql57To57InnoDB) }
    func testStandaloneAndCompoundRenameSyntax() throws {
        let t = TableName(database: "poc", table: "t")
        let u = TableName(database: "poc", table: "u")
        for syntax in ["RENAME u", "RENAME TO u", "RENAME AS u"] {
            XCTAssertEqual(try parse("ALTER TABLE t " + syntax), .rename(t, u))
        }
        let statement = try parse("ALTER TABLE t RENAME discarded,CHANGE a b INT,RENAME TO other.u")
        XCTAssertEqual(statement.alterRenameDestination, TableName(database: "other", table: "u"))
        XCTAssertEqual(try parse("ALTER TABLE t RENAME t").alterRenameDestination, t)
        XCTAssertEqual(try parse("ALTER TABLE t RENAME COLUMN a TO b"), .alter(t, [.renameColumn("a", "b")]))
        XCTAssertThrowsError(try parse("ALTER TABLE t RENAME u;DROP TABLE t"))
    }
    func testCompoundRenameRetainsChangedSchemasAndFKPeers() throws {
        guard case .create(let before, _) = try parse("CREATE TABLE t(id INT PRIMARY KEY,a INT)") else {
            return XCTFail("missing table")
        }
        guard case .create(let after, _) = try parse("CREATE TABLE t(id INT PRIMARY KEY,b INT)") else {
            return XCTFail("missing table")
        }
        guard
            case .create(let peer, _) = try parse(
                "CREATE TABLE c(id INT PRIMARY KEY,p INT,CONSTRAINT fk FOREIGN KEY(p) REFERENCES t(b))")
        else { return XCTFail("missing peer") }
        var withKeys = after
        withKeys.foreignKeys = peer.foreignKeys
        let sql = "ALTER TABLE t CHANGE a b INT,RENAME TO other.u"
        let plan = PreparedDDL(
            statement: try parse(sql), before: before, after: withKeys, sql: sql,
            additional: [.init(before: peer, after: peer)])
        let renamed = try plan.applyingAlterRename()
        XCTAssertEqual(renamed.before, before)
        XCTAssertEqual(renamed.sql, sql)
        XCTAssertEqual(renamed.after?.database, "other")
        XCTAssertEqual(renamed.after?.table, "u")
        XCTAssertEqual(renamed.after?.columns.map(\.name), ["id", "b"])
        XCTAssertEqual(renamed.additional[0].before, peer)
        XCTAssertEqual(renamed.additional[0].after?.foreignKeys[0].referencedDatabase, "other")
        XCTAssertEqual(renamed.additional[0].after?.foreignKeys[0].referencedTable, "u")
        XCTAssertEqual(renamed.additional[0].after?.foreignKeys[0].referencedColumns, ["b"])
    }
    func testFiltersIncludeRenameDestination() throws {
        let filter = try TableFilter(["excluded.%"])
        for sql in ["ALTER TABLE t ADD a INT,RENAME TO excluded.u", "ALTER TABLE excluded.t RENAME poc.u,ADD a INT"] {
            XCTAssertThrowsError(try filter.ignores(query(sql)))
        }
        XCTAssertTrue(try filter.ignores(query("ALTER TABLE excluded.t ADD a INT,RENAME AS excluded.u")))
    }
    func testNative84RenameLimitationIsNarrow() throws {
        guard case .create(var table, _) = try parse("CREATE TABLE t(id INT PRIMARY KEY)") else {
            return XCTFail("missing table")
        }
        guard
            case .create(let child, _) = try parse(
                "CREATE TABLE c(id INT PRIMARY KEY,p INT,FOREIGN KEY(p) REFERENCES t(id))")
        else { return XCTFail("missing child") }
        table.foreignKeys = child.foreignKeys
        for ending in ["", ",ALGORITHM=DEFAULT", ",ALGORITHM=INPLACE", ",FORCE"] {
            let sql = "ALTER TABLE t RENAME other.u,CHANGE id new_id INT,ADD n INT DEFAULT 7" + ending
            let plan = PreparedDDL(statement: try parse(sql), before: table, after: table, sql: sql)
            XCTAssertThrowsError(try plan.validateNativeAlterRename(profile: .mysql57To84InnoDB)) { error in
                XCTAssertTrue(String(describing: error).contains("target MySQL 8.4 native ALTER limitation"))
            }
            XCTAssertNoThrow(try plan.validateNativeAlterRename(profile: .mysql57To57InnoDB))
        }
        let childSQL = "ALTER TABLE c RENAME other.c,CHANGE p parent_id INT,ADD n INT"
        let childPlan = PreparedDDL(statement: try parse(childSQL), before: child, after: child, sql: childSQL)
        XCTAssertNoThrow(try childPlan.validateNativeAlterRename(profile: .mysql57To84InnoDB))
        for sql in [
            "ALTER TABLE t RENAME u,CHANGE id new_id INT", "ALTER TABLE t ADD n INT,RENAME t,CHANGE id new_id INT",
            "ALTER TABLE t ADD n INT,RENAME u",
        ] {
            let plan = PreparedDDL(statement: try parse(sql), before: table, after: table, sql: sql)
            XCTAssertNoThrow(try plan.validateNativeAlterRename(profile: .mysql57To84InnoDB))
        }
    }
}
