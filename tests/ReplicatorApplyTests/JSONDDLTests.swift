import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class JSONDDLTests: XCTestCase {
    func parse(_ sql:String,_ profile:ReplicationProfile) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()),profile:profile)
    }
    func testGeneratedJSONIndexesFollowTargetEngine() throws {
        for profile in ReplicationProfile.allCases {
            for storage in ["STORED","VIRTUAL"] {
                guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,doc JSON,n INT AS (doc->'$.n') \(storage),KEY by_n(n))",profile) else { return XCTFail("missing CREATE") }
                try table.validate()
                if storage == "VIRTUAL" && !profile.transactional {
                    XCTAssertThrowsError(try profile.targetContract.validateSchemaFeatures(table)) {
                        XCTAssertTrue(String(describing:$0).contains("MyISAM does not support indexes on VIRTUAL"))
                    }
                } else { XCTAssertNoThrow(try profile.targetContract.validateSchemaFeatures(table)) }
                XCTAssertEqual(table.columns[2].generationExpression,"json_extract(`doc`,'$.n')")
                XCTAssertEqual(try DMLSQLPlan(table).writeIndexes,[0,1])
            }
        }
    }
    func testFunctionalIndexesAndDefaultsUseTargetVersion() throws {
        let create="CREATE TABLE t(id INT PRIMARY KEY,doc JSON DEFAULT (JSON_OBJECT()),KEY by_name ((CAST(doc->>'$.name' AS CHAR(40)))))"
        for profile in ReplicationProfile.allCases {
            if profile == .mysql57To84InnoDB {
                guard case .create(let table,_)=try parse(create,profile) else { return XCTFail("missing CREATE") }
                try table.validate();try profile.targetContract.validateSchemaFeatures(table)
                XCTAssertEqual(table.columns[1].defaultExpression,"json_object()")
                XCTAssertEqual(table.secondaryIndexes[0].parts[0].expression,"cast(json_unquote(json_extract(`doc`,'$.name')) as char(40))")
                XCTAssertNil(table.secondaryIndexes[0].parts[0].column)
                XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
                XCTAssertEqual(try DMLSQLPlan(table).writeIndexes,[0,1])
            } else {
                XCTAssertThrowsError(try parse(create,profile)) { XCTAssertTrue(String(describing:$0).contains("MySQL 5.7 does not support expression defaults")) }
                XCTAssertThrowsError(try parse("CREATE INDEX by_n ON t ((CAST(doc->'$.n' AS UNSIGNED)))",profile)) { XCTAssertTrue(String(describing:$0).contains("MySQL 5.7 does not support functional indexes")) }
            }
        }
        for sql in ["ALTER TABLE t ADD doc JSON DEFAULT ('{}')","ALTER TABLE t MODIFY doc JSON DEFAULT (JSON_ARRAY())","ALTER TABLE t ALTER doc SET DEFAULT (JSON_OBJECT('x',1))"] {
            XCTAssertNoThrow(try parse(sql,.mysql57To84InnoDB))
            XCTAssertThrowsError(try parse(sql,.mysql57To57InnoDB))
        }
        XCTAssertThrowsError(try parse("CREATE TABLE t(id INT PRIMARY KEY,doc JSON DEFAULT '{}')",.mysql57To84InnoDB))
    }
    func testNativeMetadataEscapingAndJSONArrowCanonicalization() throws {
        let expression="json_unquote(json_extract(`doc`,'$.name'))"
        XCTAssertEqual(try DDLExpression.canonical("doc->>'$.name'"),expression)
        XCTAssertEqual(try DDLExpressionMetadata.canonical(#"json_unquote(json_extract(`doc`,_utf8mb4\'$.name\'))"#,mysql84:true),expression)
        XCTAssertEqual(try DDLExpressionMetadata.canonical(expression,mysql84:false),expression)
        XCTAssertEqual(try DDLExpressionMetadata.canonical(#"_utf8mb4\'{}\'"#,mysql84:true),"'{}'")
        XCTAssertEqual(try DDLExpressionMetadata.canonical(#"json_object(_utf8mb4\'quote\',_utf8mb4\'a\\\'b\\\\c\')"#,mysql84:true),#"json_object('quote','a''b\c')"#)
        XCTAssertThrowsError(try DDLExpressionMetadata.canonical(#"\x"#,mysql84:true))
        XCTAssertNotEqual(try DDLExpression.canonical("doc->'$.n'"),try DDLExpression.canonical("doc->>'$.n'"))
    }
    func testUnnamedIndexesAndNativeIndexDirections() throws {
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,doc JSON,KEY ((CAST(doc->'$.x' AS SIGNED))),KEY ((CAST(doc->'$.y' AS SIGNED))))",.mysql57To84InnoDB) else { return XCTFail("missing CREATE") }
        XCTAssertEqual(table.secondaryIndexes.map(\.name),["functional_index","functional_index_2"])
        let encoded=try JSONEncoder().encode(table)
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("implicitName"))
        for profile in ReplicationProfile.allCases {
            guard case .indexes(_, .add(let index))=try parse("CREATE INDEX ix ON t (id DESC)",profile) else { return XCTFail("missing index") }
            XCTAssertEqual(index.parts[0].direction,profile == .mysql57To84InnoDB ? "D" : "A")
        }
    }
    func testExpressionDependenciesDoNotTreatLiteralsAsColumnNames() throws {
        XCTAssertTrue(try DDLExpression.references("doc",in:DDLExpression.canonical("doc->>'$.name'")))
        XCTAssertFalse(try DDLExpression.references("doc",in:DDLExpression.canonical("JSON_OBJECT('`doc`',id)")))
        XCTAssertEqual(try DDLExpression.canonical("CAST(doc->>'$.name' AS CHAR(40)) COLLATE UTF8MB4_BIN"),"(cast(json_unquote(json_extract(`doc`,'$.name')) as char(40)) collate utf8mb4_bin)")
        XCTAssertThrowsError(try DDLExpression.canonical("JSON_OBJECT('x',)"))
        guard case .create(let table,_)=try parse("CREATE TABLE t(id INT PRIMARY KEY,doc JSON,KEY(id,(CAST(doc->'$.n' AS SIGNED))),KEY functional_index(id))",.mysql57To84InnoDB) else { return XCTFail("missing CREATE") }
        XCTAssertEqual(table.secondaryIndexes.map(\.name),["functional_index","functional_index_2"])
        XCTAssertEqual(table.secondaryIndexes[1].parts[0].column,"id")
    }
    func testOldSchemasDecodeWithoutNewExpressionFields() throws {
        let data=Data(#"{"database":"poc","table":"t","columns":[{"name":"id","type":"int","nullable":false}],"primaryKey":"id","secondaryIndexes":[{"name":"ix","unique":false,"type":"BTREE","parts":[{"column":"id","direction":"A"}]}]}"#.utf8)
        let table=try JSONDecoder().decode(ApplyTable.self,from:data)
        try table.validate()
        XCTAssertNil(table.columns[0].defaultExpression)
        XCTAssertNil(table.secondaryIndexes[0].parts[0].expression)
    }
}
