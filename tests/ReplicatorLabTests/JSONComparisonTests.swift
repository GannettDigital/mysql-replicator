import XCTest

@testable import ReplicatorLabCore

final class JSONComparisonTests: XCTestCase {
    func testPathsKeepArrayOrderAndEscapedObjectKeys() throws {
        XCTAssertEqual(
            try LabJSONComparison.paths(#"{"z":[],"a\"b":[null,{"n":18446744073709551615}]}"#),
            ["$", #"$."a\"b""#, #"$."a\"b"[0]"#, #"$."a\"b"[1]"#, #"$."a\"b"[1]."n""#, #"$."z""#])
        XCTAssertEqual(try LabJSONComparison.paths("null"), ["$"])
    }
    func testOnlyDoubleDisplayIsNormalized() throws {
        func value(_ type: String, _ text: String) throws -> String {
            try LabJSONComparison.scalar(type, text.utf8.map { String(format: "%02X", $0) }.joined())
        }
        XCTAssertEqual(try value("DOUBLE", "1"), try value("DOUBLE", "1.0"))
        XCTAssertNotEqual(try value("DOUBLE", "1.0"), try value("DOUBLE", "1.0000000000000002"))
        XCTAssertNotEqual(try value("DECIMAL", "1.00"), try value("DECIMAL", "1"))
        XCTAssertNotEqual(try value("STRING", "1.0"), try value("STRING", "1"))
        XCTAssertNotEqual(
            try value("UNSIGNED INTEGER", "18446744073709551615"), try value("UNSIGNED INTEGER", "18446744073709551614")
        )
        XCTAssertNotEqual(try value("DOUBLE", "1"), try value("INTEGER", "1"))
        XCTAssertEqual(try value("NULL", "null"), "6E756C6C")
        XCTAssertThrowsError(try LabJSONComparison.scalar("NULL", "NULL"))
        XCTAssertThrowsError(try value("DOUBLE", "not-a-number"))
    }
}
