import Foundation
import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ColumnIndexSyntaxTests:XCTestCase {
    func parse(_ sql:String,profile:ReplicationProfile = .mysql84To57MyISAM) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()),profile:profile)
    }
    func testInlineKeysAndSerialAttributes() throws {
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY)") else {return XCTFail("missing table")}
        try table.validate();XCTAssertEqual(table.primaryKeyColumns,["id"])
        XCTAssertEqual(table.secondaryIndexes.map(\.name),["a","b"])
        XCTAssertTrue(table.secondaryIndexes.allSatisfy(\.unique));XCTAssertTrue(table.columns[1].nullable)
        for sql in ["CREATE TABLE t(id SERIAL,a INT)","CREATE TABLE t(id BIGINT UNSIGNED SERIAL DEFAULT VALUE,a INT)"] {
            guard case .create(let table,_)=try parse(sql) else {return XCTFail("missing table")}
            try table.validate();XCTAssertEqual(table.columns[0].type,"bigint unsigned")
            XCTAssertEqual(table.columns[0].extra,"auto_increment");XCTAssertFalse(table.columns[0].nullable)
            XCTAssertEqual(table.secondaryIndexes.map(\.name),["id"])
            XCTAssertEqual(table.rowIdentity?.columns,["id"])
        }
    }
    func testUnnamedKeyNamesFollowNativeDeclarationOrder() throws {
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,a INT,KEY a(a),KEY(a),UNIQUE KEY(a))") else {return XCTFail("missing table")}
        try table.validate();XCTAssertEqual(table.secondaryIndexes.map(\.name),["a","a_2","a_3"])
        guard case .create(let invalid,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,a INT UNIQUE,KEY a(a))") else {return XCTFail("missing table")}
        XCTAssertThrowsError(try invalid.validate())
        guard case .alter(_,let actions)=try parse("ALTER TABLE t MODIFY a INT UNIQUE") else {return XCTFail("missing ALTER")}
        guard case .indexes(.add(let addition))=actions.last else {return XCTFail("missing key")}
        XCTAssertEqual(try addition.resolvingName(among:table.secondaryIndexes).name,"a_4")
    }
    func testGroupedColumnsAndKeys() throws {
        guard case .alter(_,let actions)=try parse("ALTER TABLE t ADD COLUMN (a INT UNIQUE,b INT DEFAULT 3,KEY by_b(b)),ADD c INT KEY") else {return XCTFail("missing ALTER")}
        XCTAssertEqual(actions.count,6)
        guard case .add(let b,_) = actions[2] else {return XCTFail("missing b")}
        XCTAssertEqual(b.name,"b");XCTAssertEqual(b.defaultValue,"3")
        for ending in ["RESTRICT","CASCADE"] {XCTAssertNoThrow(try parse("ALTER TABLE t DROP COLUMN a "+ending))}
        for sql in ["ALTER TABLE t ADD ()","ALTER TABLE t ADD (a INT,)","ALTER TABLE t ADD (a INT) FIRST"] {XCTAssertThrowsError(try parse(sql))}
    }
    func testIndexOptionsAndExecutionOptionsRetainLogicalSchema() throws {
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT,a INT COLUMN_FORMAT FIXED STORAGE DISK,PRIMARY KEY USING BTREE(id) COMMENT 'pk',KEY ix(a) KEY_BLOCK_SIZE=4 COMMENT 'ix' USING HASH)") else {return XCTFail("missing table")}
        try table.validate();XCTAssertEqual(table.secondaryIndexes[0].type,"BTREE")
        for sql in ["CREATE INDEX ix ON t(a) COMMENT 'x' ALGORITHM=DEFAULT LOCK=DEFAULT","DROP INDEX ix ON t LOCK=SHARED ALGORITHM=COPY","ALTER TABLE t ALGORITHM=COPY","ALTER TABLE t LOCK=DEFAULT","ALTER TABLE t ADD PRIMARY KEY USING BTREE(id) KEY_BLOCK_SIZE=4 COMMENT 'pk'"] {XCTAssertNoThrow(try parse(sql),sql)}
        XCTAssertNoThrow(try parse("CREATE FULLTEXT INDEX ft ON t(a) COMMENT 'search' WITH PARSER ngram KEY_BLOCK_SIZE=8"))
        XCTAssertThrowsError(try parse("CREATE INDEX ix ON t(a) WITH PARSER ngram"))
        XCTAssertThrowsError(try parse("ALTER TABLE t ADD a INT,ALGORITHM=INSTANT"))
        XCTAssertNoThrow(try parse("ALTER TABLE t ADD a INT,ALGORITHM=INSTANT",profile:.mysql57To84InnoDB))
        XCTAssertThrowsError(try parse("DROP INDEX ix ON t LOCK=DEFAULT;DROP TABLE t"))
    }
    func testNativeIndexNameBoundaries() throws {
        for (profile,limit) in [(ReplicationProfile.mysql57To57InnoDB,30),(.mysql57To84InnoDB,61)] {
            let name=String(repeating:"x",count:64)
            guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,`PRIMARY` INT,`\(name)` INT,KEY(`PRIMARY`),KEY(`PRIMARY`),KEY(`\(name)`),KEY(`\(name)`))",profile:profile) else {return XCTFail("missing table")}
            try table.validate()
            XCTAssertEqual(Set(table.secondaryIndexes.map(\.name)),Set(["PRIMARY_2","PRIMARY_3",name,String(repeating:"x",count:limit)+"_2"]))
        }
        let name=String(repeating:"中",count:24),sql="CREATE TABLE t(id INT PRIMARY KEY,`\(name)` INT,KEY(`\(name)`),KEY(`\(name)`))"
        XCTAssertNoThrow(try parse(sql,profile:.mysql57To57InnoDB))
        XCTAssertThrowsError(try parse(sql,profile:.mysql57To84InnoDB))
    }
    func testGroupedNamedConstraints() throws {
        guard case .alter(_,let actions)=try parse("ALTER TABLE t ADD (a INT,CONSTRAINT fk FOREIGN KEY(a) REFERENCES p(id),CONSTRAINT uq UNIQUE(a))",profile:.mysql57To57InnoDB) else {return XCTFail("missing ALTER")}
        XCTAssertEqual(actions.count,3)
        guard case .addForeignKey(let key,_)=actions[1],case .indexes(.add(let index))=actions[2] else {return XCTFail("missing constraints")}
        XCTAssertEqual(key.name,"fk");XCTAssertEqual(index.name,"uq")
    }

}
