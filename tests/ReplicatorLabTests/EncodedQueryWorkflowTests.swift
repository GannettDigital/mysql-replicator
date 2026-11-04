import Foundation
import XCTest

@testable import ReplicatorLabCore

final class EncodedQueryWorkflowTests: XCTestCase {
    private let test = DDLCompatibilityCases.encodedQueryText
    // Frozen ASCII transport and UTF-8 row SQL from the reviewed original case.
    private let original = [
        "SET NAMES latin1; SET @encoded_sql=CONVERT(0x435245415445205441424c452064646c636f6d7061742e60e96028696420494e54205052494d415259204b45592c762056415243484152283130292044454641554c542027e9272c622056415242494e415259283130292044454641554c542027e9272c6320454e554d2827e9272c277827292044454641554c542027e9272c656220454e554d2827e9272c2778272920434841524143544552205345542062696e6172792044454641554c542027e92729204348415241435445522053455420757466386d623420434f4c4c41544520757466386d62345f62696e USING latin1); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement",
        "INSERT INTO ddlcompat.`é`(id) VALUES(1)",
        "SET NAMES latin1; SET @encoded_sql=CONVERT(0x414c544552205441424c452064646c636f6d7061742e60e96020414c54455220434f4c554d4e2062205345542044454641554c542027fc27 USING latin1); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement",
        "INSERT INTO ddlcompat.`é`(id) VALUES(2)",
        "SET NAMES sjis; SET @encoded_sql=CONVERT(0x435245415445205441424c452064646c636f6d7061742e60955c6028696420494e54205052494d415259204b45592c762056415243484152283130292044454641554c542027955c272c622056415242494e415259283130292044454641554c542027955c2729204348415241435445522053455420757466386d623420434f4c4c41544520757466386d62345f62696e USING sjis); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement",
        "INSERT INTO ddlcompat.`表`(id) VALUES(1)",
        "SET NAMES sjis; SET @encoded_sql=CONVERT(0x414c544552205441424c452064646c636f6d7061742e60955c60204144442060955c6020494e542044454641554c542037 USING sjis); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement",
        "UPDATE ddlcompat.`表` SET `表`=8 WHERE id=1",
        "DROP TABLE ddlcompat.`é`",
        "DROP TABLE ddlcompat.`表`",
    ]

    func testPhasesKeepRestartsTransactionsAndProfiles() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        let final = try XCTUnwrap(test.finalObservations)
        try final.validate(phases)
        XCTAssertEqual(phases.map { $0.steps.count }, [2, 4, 19])
        XCTAssertEqual(test.steps.count, 25)
        XCTAssertEqual(test.steps.indices.filter { test.steps[$0].restartBefore }.map { $0 + 1 }, [3, 7])
        XCTAssertTrue(
            test.steps.allSatisfy { $0.transactions == 1 && $0.sqlTransactional == $0.sql && $0.assertionID == nil })
        XCTAssertTrue(phases.flatMap { $0.writes(transactional: false) }.allSatisfy { !$0.checkWarnings })
        XCTAssertTrue(test.profileExclusions.isEmpty)
        XCTAssertFalse(test.nativeInnoDB)
        XCTAssertEqual(final.databases, ["ddlcompat"])
        XCTAssertTrue(Set(phases.map(\.id)).isDisjoint(with: final.checks.map(\.id)))
    }

    func testOriginalSQLAndNonUTF8PayloadsStayExact() throws {
        XCTAssertEqual(test.steps.prefix(10).map { Data($0.sql.utf8) }, original.map { Data($0.utf8) })
        let latin1 = try payload(test.steps[0].sql, charset: "latin1")
        XCTAssertTrue(latin1.contains(0xe9))
        XCTAssertNil(String(data: latin1, encoding: .utf8))
        let sjis = try payload(test.steps[4].sql, charset: "sjis")
        XCTAssertNotNil(sjis.range(of: Data([0x95, 0x5c])))
        XCTAssertNil(String(data: sjis, encoding: .utf8))
        XCTAssertEqual(test.steps[8].sql, "DROP TABLE ddlcompat.`é`")
        XCTAssertEqual(test.steps[9].sql, "DROP TABLE ddlcompat.`表`")
    }

    func testRetainedPayloadsChangeOnlyQualifiedTableNames() throws {
        var offset = 10
        let histories: [([Int], String, String, String)] = [
            ([0, 1], "qe_latin1_created_é", "é", "latin1"),
            ([0, 1, 2, 3], "qe_latin1_altered_é", "é", "latin1"),
            ([4, 5], "qe_sjis_created_表", "表", "sjis"),
            ([4, 5, 6], "qe_sjis_added_表", "表", "sjis"),
            ([4, 5, 6, 7], "qe_sjis_updated_表", "表", "sjis"),
        ]
        for (indices, name, source, charset) in histories {
            for index in indices {
                let retained = test.steps[offset]
                XCTAssertFalse(retained.restartBefore)
                if [0, 2, 4, 6].contains(index) {
                    var expected = try payload(original[index], charset: charset)
                    let encodedName = charset == "latin1" ? Data([0xe9]) : Data([0x95, 0x5c])
                    let token = Data("ddlcompat.`".utf8) + encodedName + Data("`".utf8)
                    let range = try XCTUnwrap(expected.range(of: token))
                    let replacement =
                        Data("ddlcompat.`".utf8) + Data(name.dropLast().utf8) + encodedName + Data("`".utf8)
                    expected.replaceSubrange(range, with: replacement)
                    XCTAssertEqual(try payload(retained.sql, charset: charset), expected)
                } else {
                    let expected = original[index].replacingOccurrences(
                        of: "ddlcompat.`" + source + "`", with: "ddlcompat.`" + name + "`")
                    XCTAssertEqual(Data(retained.sql.utf8), Data(expected.utf8))
                }
                offset += 1
            }
        }
        XCTAssertEqual(offset, test.steps.count)
        XCTAssertEqual(test.steps.filter { $0.sql.hasPrefix("SET NAMES ") }.count, 12)
    }

    func testFourOriginalPredicatesKeepTheirRetainedStates() throws {
        let expected: [(String, String, String)] = [
            (
                "latin1-created-default-bytes",
                "SELECT HEX(v),HEX(b),HEX(c),HEX(eb) FROM ddlcompat.`qe_latin1_created_é`", "C3A9\tE9\tC3A9\tE9"
            ),
            ("latin1-altered-default-byte", "SELECT HEX(b) FROM ddlcompat.`qe_latin1_altered_é` WHERE id=2", "FC"),
            ("sjis-created-default-bytes", "SELECT HEX(v),HEX(b) FROM ddlcompat.`qe_sjis_created_表`", "E8A1A8\t955C"),
            ("sjis-updated-column", "SELECT `表` FROM ddlcompat.`qe_sjis_updated_表`", "8"),
        ]
        try checkObservations(expected)
    }

    func testAddedDefaultUpdateAndDroppedNamesRemainObservable() throws {
        let final = try XCTUnwrap(test.finalObservations)
        XCTAssertEqual(final.checks.count, 8)
        let expected: [(String, String, String)] = [
            (
                "latin1-existing-and-new-defaults",
                "SELECT id,HEX(v),HEX(b),HEX(c),HEX(eb) FROM ddlcompat.`qe_latin1_altered_é` ORDER BY id",
                "1\tC3A9\tE9\tC3A9\tE9\n2\tC3A9\tFC\tC3A9\tE9"
            ),
            (
                "sjis-materialized-column-default",
                "SELECT id,HEX(v),HEX(b),`表` FROM ddlcompat.`qe_sjis_added_表` ORDER BY id", "1\tE8A1A8\t955C\t7"
            ),
            (
                "sjis-updated-row-bytes", "SELECT id,HEX(v),HEX(b),`表` FROM ddlcompat.`qe_sjis_updated_表` ORDER BY id",
                "1\tE8A1A8\t955C\t8"
            ),
            (
                "original-tables-dropped",
                "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND BINARY TABLE_NAME IN ('é','表')",
                "0"
            ),
        ]
        try checkObservations(expected)
        XCTAssertTrue(final.checks.allSatisfy { $0.check.sql.hasPrefix("SELECT ") })
        XCTAssertTrue(final.queries().allSatisfy(\.preserveWhitespace))
        XCTAssertEqual(
            final.cleanup,
            [
                "DROP TABLE ddlcompat.`qe_latin1_created_é`,ddlcompat.`qe_latin1_altered_é`,ddlcompat.`qe_sjis_created_表`,ddlcompat.`qe_sjis_added_表`,ddlcompat.`qe_sjis_updated_表`"
            ])
    }

    func testEveryWriteRestoresUTF8BeforeItsOwnConnectionSettings() throws {
        let phases = try XCTUnwrap(DDLExecutionPhase.plan(test.steps))
        for profile in LabProfile.allCases {
            XCTAssertFalse(profile.session.contains("NO_BACKSLASH_ESCAPES"))
            for phase in phases {
                let writes = phase.writes(transactional: profile.transactionalTarget)
                let queries = try LabSQLPhase.queries(
                    writes, session: profile.session, status: profile.sourceVersion.binlogStatus)
                for (index, write) in writes.enumerated() {
                    let sql = queries[index * 4].sql
                    XCTAssertTrue(sql.hasPrefix(profile.session))
                    XCTAssertTrue(sql.hasPrefix("SET NAMES utf8mb4 COLLATE utf8mb4_bin;"))
                    XCTAssertNotNil(sql.range(of: write.sql))
                    XCTAssertTrue(sql.hasSuffix(write.sql + "; SHOW WARNINGS"))
                    XCTAssertFalse(write.checkWarnings)
                }
            }
        }
    }

    private func checkObservations(_ expected: [(String, String, String)]) throws {
        let final = try XCTUnwrap(test.finalObservations)
        for (id, sql, value) in expected {
            let observation = try XCTUnwrap(final.checks.first { $0.id == id })
            XCTAssertEqual(Data(observation.check.sql.utf8), Data(sql.utf8))
            XCTAssertEqual(observation.check.expected, value)
            for engine in ["InnoDB", "MyISAM"] {
                _ = try observation.result([id: value], engine: engine, role: "target")
                XCTAssertThrowsError(try observation.result([id: "wrong"], engine: engine, role: "target"))
            }
        }
    }

    // Decode only the fixture's fixed ASCII hex wrapper. Expected payloads come
    // from the frozen original statements, not from the production SQL parser.
    private func payload(_ script: String, charset: String) throws -> Data {
        XCTAssertTrue(script.utf8.allSatisfy { $0 < 0x80 })
        let prefix = "SET NAMES " + charset + "; SET @encoded_sql=CONVERT(0x"
        let suffix =
            " USING " + charset
            + "); PREPARE encoded_statement FROM @encoded_sql; EXECUTE encoded_statement; DEALLOCATE PREPARE encoded_statement"
        XCTAssertTrue(script.hasPrefix(prefix))
        XCTAssertTrue(script.hasSuffix(suffix))
        let hex = Array(script.dropFirst(prefix.count).dropLast(suffix.count).utf8)
        XCTAssertEqual(hex.count % 2, 0)
        var result = Data()
        for i in stride(from: 0, to: hex.count, by: 2) {
            let value = try XCTUnwrap(UInt8(String(decoding: hex[i..<i + 2], as: UTF8.self), radix: 16))
            result.append(value)
        }
        return result
    }
}
