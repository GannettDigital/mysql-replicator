import XCTest
import Foundation
import MySQLNIO
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class DDLCompatibilityTests: XCTestCase {
    func parse(_ sql: String) throws -> DDLStatement {
        try DDLStatement.parse(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testDDLTypesDefaultsAndInlineIndexesMatchDMLManifest() throws {
        let sql = """
        CREATE TABLE poc.t (
          id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
          tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT,
          amount DECIMAL(12,3) NOT NULL DEFAULT 1.25,
          note TEXT, payload MEDIUMBLOB, d DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL,
          tm TIME(3), y YEAR(4), e ENUM('a','b''c') NOT NULL, s SET('x','y'),
          v VARCHAR(20) DEFAULT 'hello',
          UNIQUE KEY lookup (v), KEY by_amount (amount,id)
        ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin
        """
        guard case .create(let table,let engine) = try parse(sql) else { return XCTFail("not CREATE") }
        XCTAssertEqual(engine,.myISAM)
        XCTAssertEqual(table.columns[0].extra,"auto_increment")
        XCTAssertEqual(table.columns[1].defaultValue,"-7")
        XCTAssertEqual(table.columns[4].defaultValue,"1.250")
        XCTAssertEqual(table.columns[10].type,"year")
        XCTAssertNil(table.columns[11].defaultValue)
        XCTAssertEqual(table.columns[13].defaultValue,"hello")
        XCTAssertEqual(table.secondaryIndexes.map(\.name),["by_amount","lookup"])
        for column in table.columns { XCTAssertNoThrow(try DMLColumnType(column.type)) }
        for sql in ["CREATE TABLE t(id INT PRIMARY KEY,x JSON)","CREATE TABLE t(id INT PRIMARY KEY,x TEXT DEFAULT 'x')","CREATE TABLE t(id INT PRIMARY KEY,x INT DEFAULT (2+3))"] { XCTAssertThrowsError(try parse(sql)) }
    }
    func testCompoundAlterRetainsOperationOrderAndColumnAttributes() throws {
        guard case .alter(_,let actions) = try parse("ALTER TABLE t CHANGE COLUMN old newer DECIMAL(12,2) NOT NULL DEFAULT 0 AFTER id, ADD COLUMN d DATE DEFAULT '2026-01-01', ALTER COLUMN v SET DEFAULT 'text', DROP INDEX old_index, ADD INDEX next_index(newer), ALGORITHM=COPY, LOCK=EXCLUSIVE") else { return XCTFail("not ALTER") }
        XCTAssertEqual(actions.count,5)
        guard case .modify(let old,let column,let position) = actions[0] else { return XCTFail("not CHANGE") }
        XCTAssertEqual(old,"old"); XCTAssertEqual(column.name,"newer"); XCTAssertEqual(column.defaultValue,"0.00"); XCTAssertEqual(position,.after("id"))
        XCTAssertNoThrow(try parse("ALTER TABLE t DROP PRIMARY KEY, ADD PRIMARY KEY(report_date,id)"))
        XCTAssertNoThrow(try parse("ALTER TABLE t ADD stamp DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)"))
    }
    func testDatabaseAliasesAndUnsupportedNewOptions() throws {
        XCTAssertEqual(try parse("ALTER SCHEMA poc DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),.alterDatabase(CreateDatabase(name:"poc",ifNotExists:false,characterSet:"utf8mb4",collation:"utf8mb4_bin")))
        XCTAssertEqual(try parse("DROP DATABASE IF EXISTS poc"),.dropDatabase("poc",ifExists:true))
        for sql in ["ALTER DATABASE poc READ ONLY=1","ALTER DATABASE poc ENCRYPTION='Y'","ALTER DATABASE poc","DROP SCHEMA poc; CREATE DATABASE other"] { XCTAssertThrowsError(try parse(sql)) }
        let drop=QueryControl(database:"poc",sql:Data("DROP DATABASE poc".utf8),errorCode:0,statusVariables:Data())
        XCTAssertThrowsError(try TableFilter(["poc.secret"]).ignores(drop))
        XCTAssertTrue(try TableFilter(["poc.%"]).ignores(drop))
    }
    func testTriggerAndEventPolicyCannotBeBypassedByDefinerOrFilters() throws {
        let queries = [
            "CREATE DEFINER=`root`@`localhost` TRIGGER tr BEFORE INSERT ON poc.t FOR EACH ROW SET NEW.x=2",
            "DROP TRIGGER IF EXISTS poc.tr",
            "CREATE DEFINER='root'@'localhost' EVENT poc.e ON SCHEDULE EVERY 1 DAY DO DELETE FROM poc.t",
            "ALTER EVENT poc.e DISABLE", "DROP EVENT IF EXISTS poc.e"
        ]
        let filter = try TableFilter(["poc.%"])
        for sql in queries {
            XCTAssertThrowsError(try parse(sql)) { XCTAssertTrue(String(describing:$0).contains("DDL policy rejects")) }
            XCTAssertThrowsError(try filter.ignores(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data())))
        }
        for json in [#"{"triggers":"allow"}"#,#"{"events":"ignore"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(DDLPolicy.self,from:Data(json.utf8)))
        }
        XCTAssertNoThrow(try JSONDecoder().decode(DDLPolicy.self,from:Data("{}".utf8)))
    }
    func testStoredRoutineCompoundBodyAndViewScope() throws {
        XCTAssertFalse(MySQLProtocol.CapabilityFlags.clientDefault.contains(.CLIENT_MULTI_STATEMENTS))
        let sql = "CREATE DEFINER=`root`@`localhost` PROCEDURE poc.p(IN v INT) SQL SECURITY INVOKER BEGIN SET v=v+1; INSERT INTO poc.t VALUES(v); END"
        guard case .object(let procedure) = try parse(sql) else { return XCTFail("not routine") }
        XCTAssertEqual(procedure.kind,.procedure)
        XCTAssertFalse(try TableFilter(["poc.t"]).ignores(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data())))
        XCTAssertTrue(try TableFilter(["poc.%"]).ignores(QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data())))
        XCTAssertNoThrow(try parse("CREATE FUNCTION poc.f(v INT) RETURNS INT DETERMINISTIC RETURN v+1"))
        XCTAssertThrowsError(try parse("CREATE FUNCTION f RETURNS INTEGER SONAME 'unsafe.so'"))
        XCTAssertNoThrow(try parse("CREATE OR REPLACE ALGORITHM=MERGE DEFINER='root'@'localhost' SQL SECURITY INVOKER VIEW poc.v AS SELECT id FROM poc.t"))
        XCTAssertThrowsError(try parse("CREATE VIEW poc.v AS SELECT id FROM poc.t; DROP TABLE poc.t"))
    }
    func testDefaultCanonicalizationPreservesExactIntegerDecimalAndBinaryValues() throws {
        XCTAssertEqual(try normalizedDefault("0007",type:DMLColumnType("int")),"7")
        XCTAssertEqual(try normalizedDefault("001.20",type:DMLColumnType("decimal(10,2)")),"1.20")
        XCTAssertEqual(try normalizedDefault("-000.00",type:DMLColumnType("decimal(10,2)")),"0.00")
        XCTAssertEqual(try normalizedDefault("hi",type:DMLColumnType("binary(5)")),"hi\0\0\0")
        XCTAssertEqual(try normalizedDefault("0",type:DMLColumnType("year")),"0000")
        XCTAssertThrowsError(try normalizedDefault("70",type:DMLColumnType("year")))
        guard case .create(let table,_) = try parse("CREATE TABLE t(id BIGINT UNSIGNED PRIMARY KEY DEFAULT 18446744073709551615)") else {return XCTFail("not CREATE")}
        XCTAssertEqual(table.columns[0].defaultValue,"18446744073709551615")
    }
    func testRejectionPolicyDoesNotRequireExecutableQueryContext() throws {
        let query=QueryControl(database:"poc",sql:Data("CREATE DEFINER=`root`@`localhost` TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET NEW.n=7".utf8),errorCode:0,statusVariables:Data([255]))
        XCTAssertThrowsError(try DDLStatement.parse(query)) { XCTAssertTrue($0 is ProhibitedDDL) }
        XCTAssertThrowsError(try TableFilter().ignores(query)) { XCTAssertTrue($0 is ProhibitedDDL) }
    }
    func testQueryContextCarriesSourceClockAndTimezone() throws {
        let status=Data([1,0,0,0,0,0,0,0,0,4,45,0,46,0,46,0,5,6])+Data("+00:00".utf8)+Data([13,64,226,1,16,1])
        let context=try QuerySessionContext(query:QueryControl(database:"poc",sql:Data(),errorCode:0,statusVariables:status))
        XCTAssertEqual(context.timeZone,"+00:00"); XCTAssertEqual(context.microseconds,123456)
        XCTAssertEqual(context.explicitDefaultsForTimestamp,true)
    }
    func testGeneratedColumnPlansBindOnlyBaseColumnsButReadFullImage() throws {
        guard case .create(let table,_) = try parse("CREATE TABLE t(id INT PRIMARY KEY, n INT, doubled INT GENERATED ALWAYS AS (n * 2) STORED, added INT AS ((n+1)) VIRTUAL)") else { return XCTFail("not CREATE") }
        try table.validate()
        XCTAssertEqual(table.columns[2].generationExpression,"(`n` * 2)")
        XCTAssertEqual(try DDLExpression.canonical("((`n` * 2))"),table.columns[2].generationExpression)
        XCTAssertNotEqual(try DDLExpression.canonical("(n+1)*2"),try DDLExpression.canonical("n+1*2"))
        let plan = try DMLSQLPlan(table)
        XCTAssertEqual(plan.writeIndexes,[0,1])
        XCTAssertEqual(plan.generatedIndexes,[2,3])
        XCTAssertEqual(plan.insert,"INSERT INTO `poc`.`t` (`id`,`n`) VALUES (?,?)")
        XCTAssertEqual(plan.update,"UPDATE `poc`.`t` SET `id`=?,`n`=? WHERE `id`=?")
        XCTAssertTrue(plan.select.contains("`doubled`")); XCTAssertTrue(plan.select.contains("`added`"))
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY,n INT AS (RAND()))"))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
    }
    func testQuotedEngineDoesNotRequireExpressionCollationOrConsumeTrailingLiteral() throws {
        let tokens=try DDLTokens.lex(Data("CREATE TABLE t(id INT PRIMARY KEY) ENGINE='DEFAULT'".utf8))
        XCTAssertFalse(DDLTokens.requiresConnectionCollation(tokens))
        XCTAssertTrue(DDLTokens.requiresConnectionCollation(try DDLTokens.lex(Data("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(10) DEFAULT 'DEFAULT')".utf8))))
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY) ENGINE=MyISAM 'ignored'"))
    }
    func testRangePartitionLifecycleAndExchangeFiltering() throws {
        guard case .create(let table,_) = try parse("CREATE TABLE t(report_date DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION p0 VALUES LESS THAN ('2026-01-01'),PARTITION p1 VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))") else { return XCTFail("not CREATE") }
        try table.validate()
        XCTAssertEqual(table.partitions.map(\.name),["p0","p1","future"])
        XCTAssertEqual(table.partitions[0].expression,"`report_date`")
        XCTAssertEqual(try PartitionChange.drop(["p0"]).applying(to:table).partitions.map(\.name),["p1","future"])
        XCTAssertEqual(try PartitionChange.truncate(["p0"]).applying(to:table),table)
        XCTAssertThrowsError(try PartitionChange.drop(["missing"]).applying(to:table))
        XCTAssertThrowsError(try PartitionChange.drop(["p0","p1","future"]).applying(to:table))
        let exchange = "ALTER TABLE poc.t EXCHANGE PARTITION p0 WITH TABLE otherdb.staging WITH VALIDATION"
        XCTAssertNoThrow(try parse(exchange))
        XCTAssertThrowsError(try TableFilter(["otherdb.%"]).ignores(QueryControl(database:"poc",sql:Data(exchange.utf8),errorCode:0,statusVariables:Data())))
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
    }
    func testHashPartitionsAndNoSubpartitionFallback() throws {
        guard case .create(let table,_) = try parse("CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY HASH(id) PARTITIONS 4") else { return XCTFail("not CREATE") }
        XCTAssertEqual(table.partitions.map(\.name),["p0","p1","p2","p3"])
        XCTAssertEqual(try PartitionChange.coalesce(2).applying(to:table).partitions.count,2)
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY) PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) (PARTITION p0 VALUES LESS THAN (10))"))
    }
}
