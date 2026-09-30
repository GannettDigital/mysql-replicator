import XCTest
import Foundation
import ReplicatorCodec

protocol BinlogFixtures {}
extension BinlogFixtures {
    var directory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    var root: URL { directory.deletingLastPathComponent().deletingLastPathComponent() }
    var recorded: URL { directory.deletingLastPathComponent().appendingPathComponent("ReplicatorLabTests/Fixtures") }
    func schema(_ name: String) throws -> SchemaHistory { try JSONDecoder().decode(SchemaHistory.self, from: Data(contentsOf: directory.appendingPathComponent("Schema/\(name).json"))) }
    func frames(_ data: Data) -> [(UInt64, Data)] {
        var offset = 4, result: [(UInt64, Data)] = []
        while offset < data.count {
            let count = (0..<4).reduce(0) { $0 | Int(data[offset+9+$1]) << (8*$1) }
            result.append((UInt64(offset), data.subdata(in: offset..<offset+count))); offset += count
        }
        return result
    }
    // Independent bitwise IEEE CRC32, deliberately not the production Rust path.
    func checksum(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
    func le<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
    func reseal(_ frame: Data) -> Data { let body = Data(frame.dropLast(4)); return body + le(checksum(body)) }
    func event(_ type: UInt8, _ body: Data, at position: UInt64) -> Data {
        let n = UInt32(23 + body.count)
        let raw = le(UInt32(0)) + Data([type]) + le(UInt32(8401)) + le(n) + le(UInt32(position) + n) + le(UInt16(0)) + body
        return raw + le(checksum(raw))
    }
    func failure(_ code: Int32, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual((error as? DecoderError)?.code, code, String(describing: error), file: file, line: line)
        }
    }
    func temporary(_ data: Data, _ work: (URL) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("decoder-test-" + UUID().uuidString)
        try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        try work(file)
    }
}
