import XCTest

@testable import ReplicatorLabCore

final class NativeChoiceDefinitionTests: XCTestCase {
    func testBinaryPartitionBounds() throws {
        var raw = Data("PARTITION p VALUES IN('".utf8)
        raw.append(contentsOf: [0x80, 0xff])
        raw.append(Data("','')".utf8))
        let modern = Data("PARTITION p VALUES IN(_binary 0x80FF,'')".utf8)
        XCTAssertEqual(try NativeChoiceDefinition.partitionBounds(raw, partition: "p"), "X'80ff',X''")
        XCTAssertEqual(try NativeChoiceDefinition.partitionBounds(modern, partition: "p"), "X'80ff',X''")
        XCTAssertThrowsError(try NativeChoiceDefinition.partitionBounds(modern, partition: "q"))
        XCTAssertThrowsError(
            try NativeChoiceDefinition.partitionBounds(Data("PARTITION p VALUES IN(_binary 0xGG)".utf8), partition: "p")
        )
    }
    func testNativeVersionPresentationsPreserveTheSameRawBytes() throws {
        let old =
            Data("t\tCREATE TABLE `t` (\n  `v` enum('".utf8) + Data([255])
            + Data("','a') CHARACTER SET binary DEFAULT '".utf8) + Data([255]) + Data("'\n) ENGINE=InnoDB\n".utf8)
        let new = Data(
            "t\tCREATE TABLE `t` (\n  `v` enum(x'ff','a') CHARACTER SET binary COLLATE binary DEFAULT 0xFF\n) ENGINE=InnoDB\n"
                .utf8)
        let a = try NativeChoiceDefinition.read(old, column: "v")
        let b = try NativeChoiceDefinition.read(new, column: "v")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.type, "enum(X'ff',X'61')")
        XCTAssertEqual(a.defaultValue, "X'ff'")
        XCTAssertThrowsError(try NativeChoiceDefinition.read(new, column: "missing"))
    }
}
