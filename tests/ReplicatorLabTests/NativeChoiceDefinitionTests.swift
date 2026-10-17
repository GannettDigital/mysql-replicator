import XCTest
@testable import ReplicatorLabCore

final class NativeChoiceDefinitionTests:XCTestCase {
    func testNativeVersionPresentationsPreserveTheSameRawBytes() throws {
        let old=Data("t\tCREATE TABLE `t` (\n  `v` enum('".utf8)+Data([255])+Data("','a') CHARACTER SET binary DEFAULT '".utf8)+Data([255])+Data("'\n) ENGINE=InnoDB\n".utf8)
        let new=Data("t\tCREATE TABLE `t` (\n  `v` enum(x'ff','a') CHARACTER SET binary COLLATE binary DEFAULT 0xFF\n) ENGINE=InnoDB\n".utf8)
        let a=try NativeChoiceDefinition.read(old,column:"v"),b=try NativeChoiceDefinition.read(new,column:"v")
        XCTAssertEqual(a,b)
        XCTAssertEqual(a.type,"enum(X'ff',X'61')")
        XCTAssertEqual(a.defaultValue,"X'ff'")
        XCTAssertThrowsError(try NativeChoiceDefinition.read(new,column:"missing"))
    }
}
