import XCTest
@testable import ReplicatorLabCore

final class ReverseSchemaComparisonTests: XCTestCase {
    func testPartitionIdentifierQuotingDoesNotChangeBounds() throws {
        XCTAssertEqual(try ReverseSchemaComparison.partitions("t\tp0\tHASH\t`id`\t"),"t\tp0\tHASH\tid\t")
        XCTAssertEqual(try ReverseSchemaComparison.partitions("t\tp0\tRANGE COLUMNS\t`day`, `id`\t'`literal`'"),"t\tp0\tRANGE COLUMNS\tday,id\t'`literal`'")
    }
    func testMetadataNormalizationPreservesLiterals() throws {
        func row(_ type: String, _ value: String, _ extra: String = "") -> String {
            ["t","c","1",type,"YES","","",value,extra,""].joined(separator:"\t")
        }
        let literal=row("varchar(50)","int(11) current_timestamp DEFAULT_GENERATED")
        XCTAssertEqual(try ReverseSchemaComparison.columns(literal,mysql84:true),literal)
        let labels=row("enum('int(11)','current_timestamp')","current_timestamp")
        XCTAssertEqual(try ReverseSchemaComparison.columns(labels,mysql84:true),labels)
        XCTAssertEqual(try ReverseSchemaComparison.columns(row("int(11)","7"),mysql84:false),row("int","7"))
        XCTAssertEqual(try ReverseSchemaComparison.columns(row("binary(5)","0x6869"),mysql84:true),row("binary(5)","hi\0\0\0"))
        XCTAssertEqual(try ReverseSchemaComparison.columns(row("timestamp","current_timestamp()","DEFAULT_GENERATED on update CURRENT_TIMESTAMP"),mysql84:true),row("timestamp","CURRENT_TIMESTAMP","on update CURRENT_TIMESTAMP"))
    }
}
