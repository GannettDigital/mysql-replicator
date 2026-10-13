import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class JSONTypeTests: XCTestCase {
    func testDDLDiscoveryAndDMLPlan() throws {
        var parser=try DDLParser(Data("CREATE TABLE j(id INT PRIMARY KEY,doc JSON DEFAULT NULL)".utf8),database:"poc")
        guard case .create(let table,_) = try parser.parse() else { return XCTFail("not CREATE") }
        try table.validate()
        let type=try DMLColumnType("json")
        try type.validate(.json(JSONDocument(text:"null")))
        XCTAssertThrowsError(try type.validate(.text("null")))
        XCTAssertEqual(type.interpretation,.json)
        XCTAssertTrue(type.matches(WireColumn(interpretation:.json,type:245,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([4]))))
        XCTAssertFalse(type.matches(WireColumn(interpretation:.json,type:245,maximumBytes:0,nullable:true,collation:0,primaryKey:false,name:nil,metadata:Data([1]))))
        let plan=try DMLSQLPlan(table)
        XCTAssertTrue(plan.select.contains("CAST(`doc` AS CHAR)"))
        XCTAssertEqual(plan.insert,"INSERT INTO `poc`.`j` (`id`,`doc`) VALUES (?,?)")
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(table)),table)
        for definition in ["JSON DEFAULT 'null'","JSON(10)","JSON UNSIGNED","JSON CHARACTER SET utf8mb4","JSON PRIMARY KEY"] {
            XCTAssertThrowsError(try {
                var p=try DDLParser(Data(("CREATE TABLE j(doc "+definition+")").utf8),database:"poc")
                guard case .create(let t,_) = try p.parse() else { return XCTFail("not CREATE") }
                try t.validate()
            }())
        }
    }
    func testComparisonAndRecoveryEncoding() throws {
        let json=DecodedValue.json(try JSONDocument(text:#"{"n":18446744073709551615,"v":null}"#))
        XCTAssertFalse(exactImage([json],[.null]))
        XCTAssertTrue(exactImage([json],[.json(try JSONDocument(text:#"{"v":null,"n":18446744073709551615}"#))]))
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(json)) as! [String:Any]
        XCTAssertEqual(encoded["kind"] as? String,"json")
        XCTAssertEqual(encoded["value"] as? String,#"{"n":18446744073709551615,"v":null}"#)
    }
}

extension JSONTypeTests {
    func document(_ type:Int,_ value:String,_ raw:String="",precision:Int=0,scale:Int=0) throws -> JSONDocument {
        let source:[String:Any] = ["text":"null","typed":[["path":"$","type":type,"value":value,"rawHex":raw,"precision":precision,"scale":scale]]]
        return try JSONDocument(source:JSONSerialization.data(withJSONObject:source))
    }
    func testTypedSQLPreservesNumericKindsAndBindsPaths() throws {
        let source:[String:Any] = ["text":#"{"a\"b":null,"n":null}"#,"typed":[
            ["path":#"$."a\"b""#,"type":246,"value":"123.45","rawHex":"0502807b2d","precision":5,"scale":2],
            ["path":"$.n","type":1001,"value":"18446744073709551615","rawHex":"","precision":0,"scale":0]]]
        let doc=try JSONDocument(source:JSONSerialization.data(withJSONObject:source))
        let expression=JSONSQL.document(doc,scalars:try doc.typedValues.map { try XCTUnwrap(JSONSQL.scalar($0.scalar)) })
        XCTAssertEqual(expression.sql,"JSON_SET(CAST(? AS JSON),?,JSON_EXTRACT(JSON_ARRAY(CAST(? AS DECIMAL(5,2))),'$[0]'),?,JSON_EXTRACT(JSON_ARRAY(CAST(? AS UNSIGNED)),'$[0]'))")
        XCTAssertEqual(expression.binds.map(\.string),[doc.text,#"$."a\"b""#,"123.45",#"$."n""#,"18446744073709551615"])
        let signed=try document(1000,"9223372036854775807")
        XCTAssertTrue(try XCTUnwrap(JSONSQL.scalar(signed.typedValues[0].scalar)).sql.contains("AS SIGNED"))
        let value=DecodedValue.json(doc)
        let recovery=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
        XCTAssertEqual((recovery["typedValues"] as? [[String:Any]])?.count,2)
        XCTAssertEqual(doc.scalarChecks.map(\.type),["DECIMAL","UNSIGNED INTEGER"])
        XCTAssertTrue(try doc.matchesTargetText(#"{"a\"b":123.45,"n":18446744073709551615}"#))
        XCTAssertFalse(try doc.matchesTargetText(#"{"a\"b":123.46,"n":18446744073709551615}"#))
    }
    func testTemporalParametersUseBinaryProtocolIncludingZeroDates() throws {
        func raw(_ packed:Int64) -> String {
            var n=packed.littleEndian
            return withUnsafeBytes(of:&n) { $0.map { String(format:"%02x",$0) }.joined() }
        }
        let whole=((((Int64(2024)*13+2)<<5)|29)<<17)|(12<<12)|(34<<6)|56
        let datetime=try document(12,"2024-02-29 12:34:56.123456",raw((whole<<24)|123456))
        let expression=try XCTUnwrap(JSONSQL.scalar(datetime.typedValues[0].scalar))
        XCTAssertEqual(expression.sql,"JSON_EXTRACT(JSON_ARRAY(?),'$[0]')")
        XCTAssertEqual(expression.binds.first?.type,.datetime)
        XCTAssertEqual(expression.binds.first?.buffer.map { Array($0.readableBytesView) },[0xe8,7,2,29,12,34,56,0x40,0xe2,1,0])
        let zero=try document(10,"0000-00-00","0000000000000000")
        let date=try XCTUnwrap(JSONSQL.scalar(zero.typedValues[0].scalar))
        XCTAssertEqual(date.binds.first?.type,.date)
        XCTAssertEqual(date.binds.first?.buffer.map { Array($0.readableBytesView) },[0,0,0,0])
        let time=try document(11,"-838:59:59.123456",raw(-(((Int64(838)<<12)|(59<<6)|59)<<24|123456)))
        let t=try XCTUnwrap(JSONSQL.scalar(time.typedValues[0].scalar))
        XCTAssertEqual(t.binds.first?.type,.time)
        XCTAssertEqual(t.binds.first?.buffer.map { Array($0.readableBytesView) },[1,34,0,0,0,22,59,59,0x40,0xe2,1,0])
    }
    func testOpaqueFieldConstructorsRetainSubtypeAndBytes() throws {
        for (code,name) in [(249,"TINYBLOB"),(250,"MEDIUMBLOB"),(251,"LONGBLOB"),(252,"BLOB"),(15,"VARBINARY(2)"),(254,"BINARY(2)"),(16,"BIT(16)")] {
            let doc=try document(code,"","00ff"), scalar=doc.typedValues[0].scalar
            XCTAssertNil(JSONSQL.scalar(scalar))
            let (definition,bind)=try JSONSQL.scratchDefinition(scalar)
            XCTAssertEqual(definition,name+" NULL")
            if code != 16 { XCTAssertEqual(bind.buffer.map { Array($0.readableBytesView) },[0,255]) }
        }
        let stamp=try document(7,"2024-02-29 12:34:56.123456","0000000000000000")
        XCTAssertEqual(try JSONSQL.scratchDefinition(stamp.typedValues[0].scalar).0,"TIMESTAMP(6) NULL")
        let unknown=try document(255,"","0102")
        XCTAssertThrowsError(try JSONSQL.scratchDefinition(unknown.typedValues[0].scalar))
    }
    func testTextComparisonRequiresSeparateTypeChecks() throws {
        let double=try JSONDocument(text:"1.0"),integer=try document(1000,"1")
        XCTAssertTrue(try double.matchesTargetText("1")) // Native 5.7 display can omit .0.
        XCTAssertTrue(try integer.matchesTargetText("1"))
        XCTAssertEqual(double.scalarChecks.first?.type,"DOUBLE")
        XCTAssertEqual(integer.scalarChecks.first?.type,"INTEGER")
        XCTAssertNotEqual(double,integer)
        let uint=try document(1001,"1")
        XCTAssertEqual(uint.scalarChecks.first?.type,"UNSIGNED INTEGER")
        XCTAssertNotEqual(uint,integer)
        let decimal=try document(246,"1.00","0302800100",precision:3,scale:2)
        XCTAssertTrue(try decimal.matchesTargetText("1.00"))
        XCTAssertFalse(try decimal.matchesTargetText("1"))
    }
}
