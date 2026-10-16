import Foundation
import XCTest

@testable import MySQLSyntax

final class SQLPartitionClauseTests: XCTestCase {
    func parse(_ sql: String) throws -> SQLPartitionClause {
        let tokens = try SQLLexer.lex(Data(sql.utf8))
        let result = try SQLPartitionClause.parsePrefix(tokens[...])
        XCTAssertEqual(result.consumed, tokens.count)
        return result
    }
    func testMethodsCountsAndNestedExpressions() throws {
        let value = try parse(
            "BY RANGE COLUMNS(d,id) PARTITIONS 2 SUBPARTITION BY LINEAR KEY ALGORITHM=2(id) SUBPARTITIONS 2 (PARTITION early VALUES LESS THAN ('2026-01-01',MAXVALUE),PARTITION late VALUES LESS THAN(MAXVALUE,MAXVALUE))"
        )
        XCTAssertEqual(value.method.name, "RANGE COLUMNS")
        XCTAssertEqual(value.subpartition?.name, "LINEAR KEY")
        XCTAssertEqual(value.subpartition?.algorithm, 2)
        XCTAssertEqual(value.count, 2)
        XCTAssertEqual(value.subpartitionCount, 2)
        XCTAssertEqual(value.items.map(\.name), ["early", "late"])
        XCTAssertEqual(try parse("BY KEY ALGORITHM=1() PARTITIONS 3").method.expression, [])
        XCTAssertEqual(try parse("BY LINEAR HASH(YEAR(d)+id) PARTITIONS 4").method.name, "LINEAR HASH")
        XCTAssertEqual(
            try parse("BY LIST COLUMNS(id) (PARTITION p VALUES IN(1,NULL))").items.first?.range, false)
    }
    func testNamedSubpartitionsAndPhysicalOptions() throws {
        let value = try parse(
            "BY LIST(id) SUBPARTITION BY HASH(id) (PARTITION p VALUES IN(1,2) STORAGE ENGINE=InnoDB COMMENT='a,b' (SUBPARTITION `s``0` ENGINE=InnoDB MAX_ROWS=100 MIN_ROWS=0, SUBPARTITION s1 DATA DIRECTORY='/tmp' INDEX DIRECTORY='/tmp' TABLESPACE ts NODEGROUP=0))"
        )
        XCTAssertEqual(value.items[0].engine, "InnoDB")
        XCTAssertEqual(value.items[0].children.map(\.name), ["s`0", "s1"])
        let items = try SQLPartitionClause.parseItemsPrefix(
            SQLLexer.lex(Data("(PARTITION p0,PARTITION p1) , ALGORITHM=COPY".utf8))[...])
        XCTAssertEqual(items.items.count, 2)
        XCTAssertNil(items.items[0].values)
    }
    func testNativeLastOptionAndStringSubpartitionName() throws {
        let value = try parse(
            "BY RANGE(id) SUBPARTITION BY HASH(id)(PARTITION p VALUES LESS THAN MAXVALUE COMMENT='first' COMMENT='last' (SUBPARTITION 'child' ENGINE=MyISAM ENGINE='InnoDB'))"
        )
        XCTAssertEqual(value.items[0].children[0].name, "child")
        XCTAssertEqual(value.items[0].children[0].engine, "InnoDB")
    }
    func testMalformedGrammarAndBoundedCounts() throws {
        for sql in [
            "", "BY", "BY HASH()", "BY RANGE(id)", "BY HASH(id) PARTITIONS 0",
            "BY HASH(id) PARTITIONS 8193", "BY HASH(id) PARTITIONS x", "BY KEY ALGORITHM=3(id)",
            "BY HASH ALGORITHM=2(id)", "BY LINEAR RANGE(id)", "BY HASH COLUMNS(id)",
            "BY HASH(id) SUBPARTITION BY HASH(id)", "BY RANGE(id) SUBPARTITION BY LIST(id)",
            "BY RANGE(id) SUBPARTITION BY KEY()", "BY HASH((id)", "BY HASH(id; DROP TABLE t)",
            "BY LIST(id) (PARTITION p VALUES IN())",
            "BY RANGE(id) PARTITIONS 2 (PARTITION p VALUES LESS THAN MAXVALUE)",
            "BY HASH(id) (PARTITION p(SUBPARTITION s))", "BY HASH(id) (PARTITION p COMMENT=3)",
            "BY HASH(id) (PARTITION p MIN_ROWS=-1)", "BY HASH(id) (PARTITION '(')",
        ] {
            XCTAssertThrowsError(
                try SQLPartitionClause.parsePrefix(SQLLexer.lex(Data(sql.utf8))[...]), sql)
        }
    }
}
