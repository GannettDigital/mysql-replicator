import XCTest

@testable import ReplicatorLabCore

final class NativeFulltextParserTests: XCTestCase {
    private func output(_ clause: String) -> String {
        "t\tCREATE TABLE `t` (\n  `id` int NOT NULL,\n  `body` text,\n  \(clause)\n) ENGINE=InnoDB"
    }

    func testNativeQuotedExecutableCommentAndPlainForms() throws {
        for clause in [
            "FULLTEXT KEY `ft` (`body`) /*!50100 WITH PARSER `ngram` */",
            "FULLTEXT KEY `ft` (`body`) /*!50100 WITH PARSER `ngram` */ ",
            "FULLTEXT INDEX ft (body) WITH PARSER ngram",
        ] {
            XCTAssertEqual(try NativeFulltextParser.read(output(clause), index: "ft"), "ngram")
        }
        XCTAssertEqual(
            try NativeFulltextParser.read(output("FULLTEXT KEY `f``t` (`body`) WITH PARSER `ngram`"), index: "f`t"),
            "ngram")
    }

    func testMissingWrongOrOtherIndexParserFailsObservation() throws {
        let check = DDLFinalObservations.Observation(
            id: "parser", check: .init("SHOW CREATE TABLE t", "ngram"), fulltextParserIndex: "ft")
        for clause in [
            "FULLTEXT KEY ft(body)",
            "FULLTEXT KEY ft(body) WITH PARSER mecab",
            "FULLTEXT KEY other(body) WITH PARSER ngram, FULLTEXT KEY ft(body)",
            "KEY ft(body), FULLTEXT KEY other(body) WITH PARSER ngram",
            "FULLTEXT KEY ft(body) COMMENT 'WITH PARSER ngram'",
            "FULLTEXT KEY ft(body) /* WITH PARSER ngram */",
            "`FULLTEXT KEY ft(body) WITH PARSER ngram` text",
            "body2 TEXT COMMENT 'FULLTEXT KEY ft(body) WITH PARSER ngram', FULLTEXT KEY ft(body)",
            "FULLTEXT KEY ft(body) WITH PARSER 'ngram'",
        ] {
            XCTAssertThrowsError(try check.result(["parser": output(clause)], engine: "InnoDB", role: "target"), clause)
        }
    }

    func testMalformedMetadataCannotPass() throws {
        for value in [
            "", "CREATE TABLE t (FULLTEXT KEY ft(body) WITH PARSER ngram)",
            "t\tgarbage (FULLTEXT KEY ft(body) WITH PARSER ngram)",
            "t\tCREATE TABLE t (FULLTEXT KEY ft(body) WITH PARSER ngram",
            output("FULLTEXT KEY ft(body) /*!50100 WITH PARSER ngram"),
            output("FULLTEXT KEY ft(body) WITH PARSER `ngram"),
            output("FULLTEXT KEY ft(body) WITH PARSER"),
            output("FULLTEXT KEY ft(body) WITH PARSER ngram WITH PARSER ngram"),
            output("FULLTEXT KEY ft(body) WITH PARSER ngram, FULLTEXT KEY ft(body) WITH PARSER ngram"),
        ] { XCTAssertThrowsError(try NativeFulltextParser.read(value, index: "ft"), value) }
    }

    func testRawMetadataIsKeptInEvidence() throws {
        let raw = output("FULLTEXT KEY ft(body) /*!50100 WITH PARSER `ngram` */")
        let check = DDLFinalObservations.Observation(
            id: "parser", check: .init("SHOW CREATE TABLE t", "ngram"), fulltextParserIndex: "ft")
        let result = try check.result(["parser": raw], engine: "MyISAM", role: "target")
        XCTAssertEqual(result["value"] as? String, raw)
        XCTAssertEqual(result["parser"] as? String, "ngram")
        XCTAssertEqual(result["fulltextIndex"] as? String, "ft")
        // A literal with punctuation cannot split a definition into false clauses.
        XCTAssertEqual(
            try NativeFulltextParser.read(
                output("note TEXT COMMENT 'x, ) \\' WITH PARSER fake', FULLTEXT KEY ft(body) WITH PARSER ngram"),
                index: "ft"), "ngram")
    }
}
