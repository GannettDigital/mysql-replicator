import Foundation
import XCTest

@testable import ReplicatorApply

final class ForeignKeySyntaxColumnTests: XCTestCase {
    func parser(_ sql: String, profile: ReplicationProfile = .mysql57To84InnoDB) throws -> DDLParser {
        var p = try DDLParser(Data(sql.utf8), database: "poc")
        p.engine = "InnoDB"
        p.targetVersion = profile.targetContract.versionPrefix
        p.nativeRules = NativeReplicationRules(profile: profile)
        return p
    }
    func testConstraintAndSupportingIndexNames() throws {
        for (clause, keyName, indexName) in [
            ("FOREIGN KEY ix(pid)", "child_ibfk_1", "ix"),
            ("CONSTRAINT FOREIGN KEY ix(pid)", "child_ibfk_1", "ix"),
            ("CONSTRAINT fk FOREIGN KEY ix(pid)", "fk", "fk"),
        ] {
            var p = try parser("CREATE TABLE child(id INT PRIMARY KEY,pid INT," + clause + " REFERENCES parent(id))")
            guard case .create(let table, _) = try p.parse() else { return XCTFail("missing CREATE") }
            XCTAssertEqual(table.foreignKeys.first?.name, keyName)
            XCTAssertEqual(table.secondaryIndexes.first?.name, indexName)
        }
    }
    func testMatchPreservesSource57ActionsAndSQLBytes() throws {
        for profile in [ReplicationProfile.mysql57To84InnoDB, .mysql57To57InnoDB] {
            for match in ["FULL", "PARTIAL", "SIMPLE"] {
                let prefix =
                    "CREATE TABLE c(id INT PRIMARY KEY,pid INT,n VARCHAR(50) DEFAULT 'MATCH FULL ON DELETE CASCADE',FOREIGN KEY(pid) REFERENCES p(id) "
                let raw = Data(
                    (prefix + "MATCH " + match + " ON DELETE CASCADE ON UPDATE SET NULL) COMMENT='MATCH FULL'").utf8)
                var p = try parser(String(decoding: raw, as: UTF8.self), profile: profile)
                guard case .create(let table, _) = try p.parse() else { return XCTFail("missing CREATE") }
                XCTAssertEqual(table.foreignKeys.first?.onDelete, p.nativeRules.foreignKeyDefaultAction)
                XCTAssertEqual(table.foreignKeys.first?.onUpdate, p.nativeRules.foreignKeyDefaultAction)
                XCTAssertEqual(p.ignoredForeignKeyMatchCount, 1)
                XCTAssertEqual(p.translatedSQL(raw), prefix + ") COMMENT='MATCH FULL'")
            }
        }
    }
    func testMatchAlterAndFoldedParentNames() throws {
        let sql = "ALTER TABLE C ADD FOREIGN KEY ix(pid) REFERENCES POC.P(id) MATCH SIMPLE ON DELETE CASCADE"
        var p = try parser(sql)
        p.lowerCaseTableNames = 1
        guard case .alter(_, let actions) = try p.parse(), case .addForeignKey(let key, let index) = actions.first
        else { return XCTFail("missing FK") }
        XCTAssertEqual(key.referencedDatabase, "poc")
        XCTAssertEqual(key.referencedTable, "p")
        XCTAssertEqual(index, "ix")
        XCTAssertEqual(p.translatedSQL(Data(sql.utf8)), "ALTER TABLE C ADD FOREIGN KEY ix(pid) REFERENCES POC.P(id) ")
    }
    func column(_ type: String, collation: String = "utf8mb4_bin") throws -> ApplyColumn {
        let encoding =
            type.hasPrefix("VARCHAR") || type.hasPrefix("CHAR") ? " CHARACTER SET utf8mb4 COLLATE " + collation : ""
        var p = try parser("CREATE TABLE t(id INT PRIMARY KEY,v " + type + encoding + ")")
        guard case .create(let table, _) = try p.parse() else { throw ApplyError("missing CREATE") }
        return table.columns[1]
    }
    func testNativeStorageCompatibility() throws {
        let accepted = [
            ("VARCHAR(10)", "CHAR(20)"), ("VARBINARY(10)", "BINARY(20)"), ("DECIMAL(10,2)", "DECIMAL(12,3) UNSIGNED"),
            ("BIT(3)", "BIT(8)"), ("TIME(2)", "DATETIME(6)"), ("ENUM('a','b')", "ENUM('c','d','e')"),
            ("YEAR", "TINYINT UNSIGNED"), ("DATE", "MEDIUMINT"), ("FLOAT(10,2)", "FLOAT"),
            ("SET('a','b')", "TINYINT UNSIGNED"),
        ]
        for (a, b) in accepted {
            XCTAssertTrue(try ForeignKeyColumnCompatibility.matches(column(a), column(b)), a + " / " + b)
        }
        for (a, b) in [
            ("INT", "INT UNSIGNED"), ("INT", "BIGINT"), ("DATE", "MEDIUMINT UNSIGNED"), ("FLOAT", "DOUBLE"),
            ("VARCHAR(10)", "VARBINARY(10)"), ("SET('a','b')", "SMALLINT UNSIGNED"),
        ] {
            XCTAssertFalse(try ForeignKeyColumnCompatibility.matches(column(a), column(b)), a + " / " + b)
        }
        XCTAssertFalse(
            try ForeignKeyColumnCompatibility.matches(
                column("VARCHAR(10)"), column("VARCHAR(20)", collation: "utf8mb4_unicode_ci")))
    }
}
