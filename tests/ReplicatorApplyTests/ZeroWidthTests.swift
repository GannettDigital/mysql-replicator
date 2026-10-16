import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class ZeroWidthTests:XCTestCase {
    func testNativeZeroWidthColumnsAcceptOnlyEmptyNonNullValues() throws {
        for base in ["char","varchar","binary","varbinary"] {
            let text=["char","varchar"].contains(base)
            let column=ApplyColumn(name:"v",type:base+"(0)",nullable:true,collation:text ? "utf8mb4_bin" : nil,characterSet:text ? "utf8mb4" : nil)
            try column.validate()
            XCTAssertEqual(column.width,0)
            try column.validate(.null)
            try column.validate(text ? .text("") : .binary(Data()))
            XCTAssertThrowsError(try column.validate(text ? .text("a") : .binary(Data([0]))))
            let type=try DMLColumnType(column)
            let code:UInt32=["char","binary"].contains(base) ? 254 : 15
            let wire=WireColumn(interpretation:column.interpretation,type:code,maximumBytes:0,nullable:true,collation:text ? 46 : 63,primaryKey:false,name:"v")
            XCTAssertTrue(type.matches(wire))
        }
    }
}
