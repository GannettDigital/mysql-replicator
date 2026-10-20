import Foundation
import XCTest

@testable import ReplicatorApply

extension ForeignKeyTests {
    func testMissingParentAllowancePreservesRelationshipAndChildChecks() throws {
        let child = try schema(
            "c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES p(id) ON DELETE CASCADE)")
        let parent = SQLNameKey.table("poc", "p")
        XCTAssertThrowsError(
            try ForeignKeyGraph.validate(child.foreignKeys, tables: [child.identity: child], filter: TableFilter()))
        XCTAssertNoThrow(
            try ForeignKeyGraph.validate(
                child.foreignKeys, tables: [child.identity: child], filter: TableFilter(), missingParents: [parent]))
        XCTAssertThrowsError(
            try ForeignKeyGraph.validate(
                child.foreignKeys, tables: [:], filter: TableFilter(), missingParents: [parent, child.identity]))
        XCTAssertThrowsError(
            try ForeignKeyGraph.validate(
                child.foreignKeys, tables: [child.identity: child], filter: TableFilter(["poc.p"]),
                missingParents: [parent]))
        let noIndex = child.replacing(indexes: [])
        XCTAssertThrowsError(
            try ForeignKeyGraph.validate(
                child.foreignKeys, tables: [child.identity: noIndex], filter: TableFilter(), missingParents: [parent]))
        let saved = try JSONDecoder().decode(
            SchemaTransition.self, from: JSONEncoder().encode(SchemaTransition(before: nil, after: child)))
        XCTAssertEqual(saved.after?.foreignKeys, child.foreignKeys)
    }

    func testRecreatedParentMustMatchReferencedColumns() throws {
        let child = try schema("c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES p(id))")
        for definition in ["p(id BIGINT PRIMARY KEY)", "p(other INT PRIMARY KEY)"] {
            let parent = try schema(definition)
            XCTAssertThrowsError(
                try ForeignKeyGraph.validate(
                    child.foreignKeys, tables: [child.identity: child, parent.identity: parent], filter: TableFilter(),
                    missingParents: [parent.identity]))
        }
        let parent = try schema("p(id INT PRIMARY KEY)")
        XCTAssertNoThrow(
            try ForeignKeyGraph.validate(
                child.foreignKeys, tables: [child.identity: child, parent.identity: parent], filter: TableFilter()))
    }
}
