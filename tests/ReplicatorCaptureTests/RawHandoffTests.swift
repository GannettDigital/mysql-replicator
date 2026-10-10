import XCTest
import Foundation
@testable import ReplicatorCapture
import ReplicatorCodec

extension CaptureTests {
    func testRawByteHandoffMatchesExternalBase64WithoutDuplicatingGroupBytes() throws {
        let frames=try recorded().filter { $0.0 >= 1589 }
        var external:[LiveRecord]=[], internalRecords:[LiveRecord]=[], groups:[CompleteTransaction]=[]
        let text=try StreamProcessor(config:config(),includeRaw:true,emitEvent:{ external.append($0) },emitTransaction:{ _ in })
        let raw=try StreamProcessor(config:config(),includeRaw:false,retainRawBytes:true,emitEvent:{ internalRecords.append($0) },emitTransaction:{ groups.append($0) })
        for processor in [text,raw] {
            try begin(processor)
            for (_,frame) in frames { try processor.consume(frame) }
            try processor.finish()
        }
        XCTAssertEqual(external.count,internalRecords.count)
        for (expected,actual) in zip(external,internalRecords) {
            XCTAssertEqual(actual.rawBytes,(expected.event?.rawBase64 ?? expected.rawBase64).flatMap { Data(base64Encoded:$0) })
            XCTAssertNil(actual.rawBase64);XCTAssertNil(actual.event?.rawBase64)
            let json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(expected)) as! [String:Any]
            XCTAssertNil(json["rawBytes"])
        }
        XCTAssertEqual(groups.count,4)
        XCTAssertTrue(groups.flatMap(\.events).allSatisfy { $0.rawBase64 == nil })
    }
}
