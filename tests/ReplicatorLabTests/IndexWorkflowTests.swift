import XCTest

@testable import ReplicatorLabCore

final class IndexWorkflowTests: XCTestCase {
    private func verify(_ test: DDLCompatibilityCases.Case, count: Int, restarts: [Int]) throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(test.steps.count, count)
        XCTAssertEqual(phases.count, 3)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }, restarts)
        XCTAssertEqual(phases.flatMap(\.steps).map(\.sql), test.steps.map(\.sql))
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertTrue(test.steps.allSatisfy { $0.assertionID == nil && $0.transactions == 1 })
        XCTAssertEqual(final.queries().count, final.checks.count)
        for check in final.checks where check.fulltextParserIndex == nil {
            for transactional in [false, true] {
                _ = try check.result(
                    [check.id: check.selectedCheck(transactional: transactional).expected], engine: "InnoDB",
                    role: "target", transactional: transactional)
                XCTAssertThrowsError(
                    try check.result(
                        [check.id: "wrong"], engine: "MyISAM", role: "target", transactional: transactional))
            }
        }
    }

    private func prefix(
        _ test: DDLCompatibilityCases.Case, start: Int, originalStart: Int = 0, count: Int,
        replacements: [(String, String)]
    ) {
        for offset in 0..<count {
            for transactional in [false, true] {
                let before = test.steps[originalStart + offset]
                let after = test.steps[start + offset]
                let expected = replacements.reduce(transactional ? before.sqlTransactional : before.sql) {
                    $0.replacingOccurrences(of: "ddlcompat." + $1.0, with: "ddlcompat." + $1.1)
                }
                XCTAssertEqual(transactional ? after.sqlTransactional : after.sql, expected)
                XCTAssertFalse(after.restartBefore)
            }
        }
    }

    func testGeometryKeepsNullLineAndBothPrefixDefinitions() throws {
        let test = DDLCompatibilityCases.spatialPrefixIndexes
        try verify(test, count: 10, restarts: [2, 5])
        prefix(test, start: 8, count: 2, replacements: [("t", "gp_initial")])
        XCTAssertEqual(Set(test.profileExclusions.keys), [.forward, .reverse])
        let checks = try XCTUnwrap(test.finalObservations).checks
        XCTAssertEqual(checks.count, 6)
        XCTAssertEqual(
            checks.first { $0.id == "initial-point-line-and-null" }?.check.expected,
            "1\tPOINT(1 2)\n2\tLINESTRING(0 0,1 1)\n3\tNULL")
        for id in ["t-compound-prefix", "copy-compound-prefix"] {
            XCTAssertEqual(checks.first { $0.id == id }?.check.expected, "g\tBTREE\t16\t1\nid\tBTREE\tNULL\t2")
        }
        XCTAssertEqual(test.finalObservations?.cleanup, ["DROP TABLE ddlcompat.gp_initial"])
    }

    func testJSONKeepsStoredVirtualAndCopyBeforeUpdate() throws {
        let test = DDLCompatibilityCases.jsonGeneratedIndexes
        try verify(test, count: 21, restarts: [2, 8])
        XCTAssertEqual(try XCTUnwrap(DDLExecutionPhase.plan(test.steps)).map { $0.steps.count }, [2, 6, 13])
        prefix(test, start: 11, count: 2, replacements: [("t", "ji_initial")])
        prefix(test, start: 13, count: 8, replacements: [("t", "ji_before"), ("copy", "ji_copy")])
        XCTAssertTrue(test.profileExclusions.isEmpty)
        let creates = test.steps.filter { $0.sql.hasPrefix("CREATE TABLE") && $0.sql.contains("name VARCHAR") }
        XCTAssertEqual(creates.count, 3)
        for step in creates {
            XCTAssertTrue(step.sql.contains("STORED,KEY by_name"))
            XCTAssertTrue(step.sqlTransactional.contains("VIRTUAL,KEY by_name"))
        }
        let checks = try XCTUnwrap(test.finalObservations).checks
        XCTAssertEqual(checks.count, 14)
        XCTAssertEqual(
            checks.first { $0.id == "like-copy-before-update" }?.check.expected,
            "1\tgamma\t30\n3\tNULL\tNULL\n4\tdelta\t40")
        XCTAssertEqual(checks.filter { $0.transactionalCheck != nil }.count, 5)
        XCTAssertEqual(checks.filter { $0.check.sql.contains("FORCE INDEX") }.count, 5)
        XCTAssertEqual(
            test.steps[9].sql,
            "UPDATE ddlcompat.copy c JOIN ddlcompat.t s ON c.id=s.id SET c.doc=JSON_OBJECT('name','final','n',s.n+10) WHERE c.id=4")
        XCTAssertEqual(
            test.steps[10].sql,
            "USE ddlcompat; DELETE c FROM ddlcompat.copy c JOIN ddlcompat.t s ON c.id=s.id WHERE s.id=1")
        XCTAssertEqual(test.steps[9].sqlTransactional, test.steps[9].sql)
        XCTAssertEqual(test.steps[10].sqlTransactional, test.steps[10].sql)
        XCTAssertEqual(
            checks.first { $0.id == "join-copy-final-rows" }?.check.expected, "3\tNULL\tNULL\n4\tfinal\t50")
        XCTAssertEqual(
            checks.first { $0.id == "join-input-unchanged" }?.check.expected,
            "1\tgamma\t30\n3\tNULL\tNULL\n4\tdelta\t40")
        XCTAssertEqual(
            checks.first { $0.id == "delete-join-index-absence" }?.check.sql,
            "SELECT COUNT(*) FROM ddlcompat.copy FORCE INDEX(renamed_name) WHERE name='gamma'")
        XCTAssertEqual(checks.first { $0.id == "delete-join-index-absence" }?.check.expected, "0")
        XCTAssertEqual(
            test.finalObservations?.cleanup, ["DROP TABLE ddlcompat.ji_initial,ddlcompat.ji_before,ddlcompat.ji_copy"])
    }

    func testFulltextKeepsMigrationPredicatesAndParserObservations() throws {
        let test = DDLCompatibilityCases.fulltextIndexes
        try verify(test, count: 44, restarts: [2, 11])
        var start = 18
        for (name, count) in [("ft_inserted", 2), ("ft_updated", 3), ("ft_renamed", 7), ("ft_deleted", 8)] {
            prefix(test, start: start, count: count, replacements: [("t", name)])
            start += count
        }
        for (name, count) in [("ng_created", 1), ("ng_inserted", 2), ("ng_updated", 3)] {
            prefix(test, start: start, originalStart: 14, count: count, replacements: [("ngram_created", name)])
            start += count
        }
        XCTAssertEqual(start, test.steps.count)
        XCTAssertEqual(
            test.steps[9].sql,
            "CREATE TABLE ddlcompat.ngram(id INT PRIMARY KEY,body TEXT) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        let checks = try XCTUnwrap(test.finalObservations).checks
        XCTAssertEqual(checks.count, 17)
        XCTAssertEqual(
            Set(checks.filter { $0.id.hasPrefix("fulltext-ngram-") }.map(\.id)),
            ["fulltext-ngram-create", "fulltext-ngram-insert", "fulltext-ngram-update", "fulltext-ngram-delete"])
        XCTAssertEqual(
            Set(checks.filter { $0.fulltextParserIndex == "ft" }.map { $0.check.sql }),
            [
                "SHOW CREATE TABLE ddlcompat.ng_created", "SHOW CREATE TABLE ddlcompat.ngram",
                "SHOW CREATE TABLE ddlcompat.copy",
            ])
        for (id, table, predicate, term) in [
            ("fulltext-ngram-insert", "ng_inserted", "COUNT(*)=1 AND MIN(id)=1", "xyzzy"),
            ("fulltext-ngram-update", "ng_updated", "COUNT(*)=0", "xyzzy"),
            ("fulltext-ngram-delete", "ngram_created", "COUNT(*)=0", "qqvvq"),
        ] {
            XCTAssertEqual(
                checks.first { $0.id == id }?.check.sql,
                "SELECT \(predicate) FROM ddlcompat.\(table) WHERE MATCH(body) AGAINST('\(term)' IN BOOLEAN MODE)")
        }
        XCTAssertFalse(checks.contains { $0.check.sql.contains("FROM ddlcompat.t WHERE MATCH") })
    }
}
