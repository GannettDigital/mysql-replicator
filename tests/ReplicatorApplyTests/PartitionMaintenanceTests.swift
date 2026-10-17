import Foundation
import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class PartitionMaintenanceTests:XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))}
    func table(_ clause:String) throws -> ApplyTable {
        guard case .create(let table,_) = try parse("CREATE TABLE t(id INT PRIMARY KEY) "+clause) else {throw ApplyError("not CREATE")}
        try table.validate();return table
    }
    func testKeyAlgorithmSavedDiscoveryAndLifecycle() throws {
        let one=try table("PARTITION BY KEY ALGORITHM=1(id) PARTITIONS 2")
        let two=try table("PARTITION BY KEY ALGORITHM=2(id) PARTITIONS 2")
        XCTAssertEqual(one.partitions.map(\.keyAlgorithm),[1,1])
        XCTAssertEqual(two.partitions.map(\.keyAlgorithm),[nil,nil])
        XCTAssertNotEqual(one,two)
        XCTAssertEqual(try JSONDecoder().decode(ApplyTable.self,from:JSONEncoder().encode(one)),one)
        XCTAssertEqual(try PartitionChange.addHash(1).applying(to:one).partitions.last?.keyAlgorithm,1)
        let native=Data("CREATE TABLE t(id INT PRIMARY KEY) /*!50100 PARTITION BY KEY */ /*!50611 ALGORITHM = 1 */ /*!50100 (id) PARTITIONS 2 */".utf8)
        XCTAssertEqual(try PartitionKeyMetadata.applying(native,to:two.partitions),one.partitions)
        XCTAssertEqual(try PartitionKeyMetadata.applying(Data("CREATE TABLE t(id INT) PARTITION BY KEY(id) PARTITIONS 2".utf8),to:one.partitions),two.partitions)
        XCTAssertThrowsError(try PartitionKeyMetadata.applying(Data("CREATE TABLE t(id INT)".utf8),to:one.partitions))
        XCTAssertThrowsError(try PartitionKeyMetadata.applying(Data("CREATE TABLE t(id INT) PARTITION BY HASH(id) PARTITIONS 2".utf8),to:one.partitions))
    }
    func testSubpartitionAlgorithmAndLegacyState() throws {
        let one=try table("PARTITION BY RANGE(id) SUBPARTITION BY LINEAR KEY ALGORITHM=1(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)")
        XCTAssertEqual(one.partitions[0].subpartitions?.map(\.keyAlgorithm),[1,1])
        guard case .alter(_,let actions)=try parse("ALTER TABLE t REORGANIZE PARTITION p INTO(PARTITION a VALUES LESS THAN(10),PARTITION b VALUES LESS THAN MAXVALUE)"),case .partition(let operation)=actions[0] else {return XCTFail()}
        XCTAssertTrue(try operation.applying(to:one).partitions.flatMap { $0.subpartitions! }.allSatisfy { $0.keyAlgorithm == 1 })
        let json=Data(#"{"name":"p","method":"RANGE","expression":"`id`","description":"MAXVALUE","subpartitions":[{"name":"psp0","method":"KEY","expression":"`id`"}]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ApplyPartition.self,from:json).subpartitions?[0].keyAlgorithm)
        XCTAssertEqual(try PartitionKeyMetadata.applying(Data("CREATE TABLE t(id INT) PARTITION BY RANGE(id) SUBPARTITION BY LINEAR KEY ALGORITHM=1(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)".utf8),to:one.partitions),one.partitions)
    }
    func testSubpartitionEqualityChecksAllSavedFields() throws {
        let original=try table("PARTITION BY RANGE(id) SUBPARTITION BY KEY(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)")
        func changed(_ edit:(inout ApplyPartition)->Void) -> ApplyTable {
            var copy=original; edit(&copy.partitions[0]); return copy
        }
        XCTAssertNotEqual(original,changed { $0.subpartitions=nil })
        XCTAssertNotEqual(original,changed { $0.subpartitions!.removeLast() })
        XCTAssertNotEqual(original,changed { $0.subpartitions!.reverse() })
        XCTAssertNotEqual(original,changed { $0.subpartitions![0] = .init(name:"other",method:"KEY",expression:"`id`") })
        XCTAssertNotEqual(original,changed { $0.subpartitions![0] = .init(name:"psp0",method:"LINEAR KEY",expression:"`id`") })
        XCTAssertNotEqual(original,changed { $0.subpartitions![0] = .init(name:"psp0",method:"KEY",expression:"`other`") })
        XCTAssertNotEqual(original,changed { $0.subpartitions![0].keyAlgorithm=1 })
        let composed=ApplySubpartition(name:"é",method:"KEY",expression:"`id`")
        let decomposed=ApplySubpartition(name:"e\u{301}",method:"KEY",expression:"`id`")
        XCTAssertNotEqual(composed,decomposed)
        XCTAssertNotEqual(ApplySubpartition(name:"same",method:"KEY",expression:"`é`"),ApplySubpartition(name:"same",method:"KEY",expression:"`e\u{301}`"))
    }
    func testMaintenanceSelectionAndResultFailures() throws {
        let schema=try table("PARTITION BY RANGE(id) SUBPARTITION BY HASH(id) SUBPARTITIONS 2(PARTITION p VALUES LESS THAN MAXVALUE)")
        for operation in ["REBUILD","ANALYZE","OPTIMIZE","REPAIR","CHECK"] {
            for selection in ["ALL","p","psp0"] {
                guard case .alter(_,let actions)=try parse("ALTER TABLE t "+operation+" PARTITION "+selection),case .partition(let change)=actions[0] else {return XCTFail()}
                XCTAssertEqual(try change.applying(to:schema),schema)
            }
        }
        guard case .alter(_,let actions)=try parse("ALTER TABLE t ANALYZE PARTITION absent"),case .partition(let change)=actions[0] else {return XCTFail()}
        XCTAssertThrowsError(try change.applying(to:schema))
        XCTAssertNoThrow(try PartitionMaintenanceResult.validate([("note","Table does not support optimize on partitions. All partitions will be rebuilt and analyzed."),("status","OK")]))
        XCTAssertNoThrow(try PartitionMaintenanceResult.validate([("status","Table is already up to date")]))
        for rows:[(String?,String?)] in [[],[(nil,"x")],[("status",nil)],[("error","corrupt table"),("status","OK")],[("status","Operation failed")],[("note","not supported")],[("warning","warning only")]] {XCTAssertThrowsError(try PartitionMaintenanceResult.validate(rows))}
    }
}
