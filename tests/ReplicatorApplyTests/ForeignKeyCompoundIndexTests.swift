import Foundation
import XCTest

@testable import ReplicatorApply

extension ForeignKeyTests {
    func testCompoundReplacementChoicesPreserveEveryOtherSchemaField() throws {
        let before = try schema("c(id INT PRIMARY KEY,a INT,b INT,n INT,KEY olda(a),KEY oldb(b),KEY unrelated(n))")
        let ca = ApplyForeignKey(
            name: "fa", database: "poc", table: "c", columns: ["a"], referencedDatabase: "poc", referencedTable: "p",
            referencedColumns: ["id"])
        var cb = ca
        cb.name = "fb"
        cb.columns = ["b"]
        let after = try before.addingForeignKey(ca, indexName: nil).addingForeignKey(cb, indexName: nil)
        let actions: [AlterAction] = [.addForeignKey(ca, nil), .addForeignKey(cb, nil), .defaultValue("n", "7")]
        let choices = ForeignKeyGraph.indexReplacements(after: after, actions: actions)
        XCTAssertEqual(choices.count, 2)
        let both = after.replacing(
            indexes: after.secondaryIndexes.map { old in choices.first(where: { $0.planned == old })?.alternative ?? old
            })
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(both, expected: after, removable: [], replacements: choices))
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(after, expected: after, removable: [], replacements: choices))
        XCTAssertFalse(
            ForeignKeyGraph.matchesIndexes(
                both.replacing(indexes: both.secondaryIndexes.filter { $0.name != "unrelated" }), expected: after,
                removable: [], replacements: choices))
        var columns = both.columns
        columns[3].defaultValue = "9"
        var changed = both.replacing(columns: columns)
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(changed, expected: after, removable: [], replacements: choices))
        changed = both
        changed.foreignKeys = []
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(changed, expected: after, removable: [], replacements: choices))
        let protected = ForeignKeyGraph.indexReplacements(
            after: after, actions: actions + [.indexes(.rename("other", "olda"))])
        XCTAssertEqual(protected.map(\.planned.name), ["oldb"])
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(both, expected: after, removable: [], replacements: protected))
    }
    func testIndexMatchingDoesNotReuseOneReplacementForTwoOldIndexes() throws {
        let expected = try schema("c(id INT PRIMARY KEY,a INT,KEY a1(a),KEY a2(a))")
        let replacement = ApplyIndex(name: "fk", unique: false, parts: [.init(column: "a", prefix: nil)])
        let choices = expected.secondaryIndexes.map {
            ForeignKeyIndexReplacement(planned: $0, alternative: replacement)
        }
        let actual = expected.replacing(indexes: [replacement])
        XCTAssertFalse(ForeignKeyGraph.matchesIndexes(actual, expected: expected, removable: [], replacements: choices))
        XCTAssertTrue(
            ForeignKeyGraph.matchesIndexes(
                actual, expected: expected, removable: [expected.secondaryIndexes[0]], replacements: choices))
        XCTAssertFalse(
            ForeignKeyGraph.matchesIndexes(
                expected.replacing(indexes: [.init(name: "wrong", unique: false, parts: replacement.parts)]),
                expected: expected, removable: expected.secondaryIndexes, replacements: choices))
    }
    func testNewImplicitIndexCanBeReplacedByLaterForeignKey() throws {
        let before = try schema("c(id INT PRIMARY KEY,a INT)")
        let first = ApplyForeignKey(
            name: "first_fk", database: "poc", table: "c", columns: ["a"], referencedDatabase: "poc",
            referencedTable: "p", referencedColumns: ["id"])
        var second = first
        second.name = "second_fk"
        let after = try before.addingForeignKey(first, indexName: nil).addingForeignKey(second, indexName: nil)
        let choices = ForeignKeyGraph.indexReplacements(
            after: after, actions: [.addForeignKey(first, nil), .addForeignKey(second, nil)])
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0].planned.name, "first_fk")
        XCTAssertEqual(choices[0].alternative.name, "second_fk")
        XCTAssertTrue(
            ForeignKeyGraph.matchesIndexes(
                after.replacing(indexes: [choices[0].alternative]), expected: after, removable: [],
                replacements: choices))
        XCTAssertTrue(
            ForeignKeyGraph.indexReplacements(
                after: after, actions: [.indexes(.add(after.secondaryIndexes[0])), .addForeignKey(second, nil)]
            ).isEmpty)
    }
    func testIndependentChoicesUseLinearJournalRecords() throws {
        let definitions = (0..<16).map { "c\($0) INT,KEY old\($0)(c\($0))" }.joined(separator: ",")
        var after = try schema("t(id INT PRIMARY KEY," + definitions + ")")
        var actions: [AlterAction] = []
        for i in 0..<16 {
            let key = ApplyForeignKey(
                name: "fk\(i)", database: "poc", table: "t", columns: ["c\(i)"], referencedDatabase: "poc",
                referencedTable: "p", referencedColumns: ["id"])
            after = try after.addingForeignKey(key, indexName: nil)
            actions.append(.addForeignKey(key, nil))
        }
        let choices = ForeignKeyGraph.indexReplacements(after: after, actions: actions)
        XCTAssertEqual(choices.count, 16)
        let actual = after.replacing(indexes: choices.map(\.alternative))
        XCTAssertTrue(ForeignKeyGraph.matchesIndexes(actual, expected: after, removable: [], replacements: choices))
    }
}
