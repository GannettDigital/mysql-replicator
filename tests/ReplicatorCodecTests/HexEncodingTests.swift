import XCTest
@testable import ReplicatorCodec

final class HexEncodingTests: XCTestCase {
    func testAllBytesMatchExistingFingerprintRepresentation() {
        let bytes = Array(UInt8.min...UInt8.max)
        let expected = bytes.map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(bytes.withUnsafeBufferPointer(HexEncoding.lowercase),expected)
        XCTAssertEqual([UInt8(0),1,15,16,128,255].withUnsafeBufferPointer(HexEncoding.lowercase),"00010f1080ff")
        XCTAssertEqual(HexEncoding.lowercase(UnsafeBufferPointer(start:nil,count:0)),"")
    }

    func testEncodedStringOwnsItsBytesAfterInputChanges() {
        var digest = [UInt8](repeating:0,count:32)
        let encoded = digest.withUnsafeBufferPointer(HexEncoding.lowercase)
        digest = [UInt8](repeating:255,count:32)
        XCTAssertEqual(encoded,String(repeating:"00",count:32))
        XCTAssertEqual(digest.withUnsafeBufferPointer(HexEncoding.lowercase),String(repeating:"ff",count:32))
    }
}
