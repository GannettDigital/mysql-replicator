/// Builds the same lowercase, zero-padded representation as `%02x` without
/// allocating and formatting a separate String for every byte.
enum HexEncoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func lowercase(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        String(unsafeUninitializedCapacity: bytes.count * 2) { output in
            for (index, byte) in bytes.enumerated() {
                output[index * 2] = digits[Int(byte >> 4)]
                output[index * 2 + 1] = digits[Int(byte & 0x0f)]
            }
            return bytes.count * 2
        }
    }
}
