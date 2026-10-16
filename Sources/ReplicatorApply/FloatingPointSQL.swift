import Foundation
import MySQLNIO
import NIOCore
import ReplicatorCodec

/// Preserve IEEE bits through the binary prepared-statement protocol. Text
/// formatting is only for schema defaults; it never compares stored row values.
enum FloatingPointSQL {
    static func bind(_ value: DecodedValue) throws -> MySQLData {
        var bytes = ByteBufferAllocator().buffer(capacity: 8)
        switch value {
        case .float32(let bits):
            try require(Float(bitPattern: bits).isFinite, "non-finite FLOAT parameter")
            bytes.writeInteger(bits, endianness: .little)
            return .init(type: .float, buffer: bytes)
        case .float64(let bits):
            try require(Double(bitPattern: bits).isFinite, "non-finite DOUBLE parameter")
            bytes.writeInteger(bits, endianness: .little)
            return .init(type: .double, buffer: bytes)
        default: throw ApplyError("expected floating-point parameter")
        }
    }
    static func read(_ value: MySQLData, type: DMLColumnType) throws -> DecodedValue {
        guard var bytes = value.buffer else { throw ApplyError("missing floating-point result") }
        let decoded: DecodedValue
        if type.floatingWidth == 32, value.type == .float, bytes.readableBytes == 4 {
            decoded = .float32(bytes.readInteger(endianness: .little, as: UInt32.self)!)
        } else if type.floatingWidth == 64, value.type == .double, bytes.readableBytes == 8 {
            decoded = .float64(bytes.readInteger(endianness: .little, as: UInt64.self)!)
        } else {
            throw ApplyError("target floating-point result type or width differs")
        }
        try type.validate(decoded)
        return decoded
    }
    static func defaultValue(_ text: String, type: DMLColumnType) throws -> String {
        try require(
            text.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
            "invalid floating-point default")
        guard var number = Double(text), number.isFinite else { throw ApplyError("non-finite floating-point default") }
        // Match Field_real::truncate for the predicted metadata. The original
        // DDL and logged SQL mode still go to MySQL; server errors remain errors.
        if type.unsigned && number < 0 { number = 0 }
        if type.arguments.count == 2 {
            // Field_real::truncate rounds the fractional part with rint before
            // clipping to the declared decimal range. Retain the original DDL.
            let scale = pow(10.0, Double(type.arguments[1]))
            number = floor(number) + ((number - floor(number)) * scale).rounded(.toNearestOrEven) / scale
            let limit = pow(10.0, Double(type.arguments[0] - type.arguments[1])) - 1 / scale
            number = min(max(number, -limit), limit)
            if type.floatingWidth == 32 { number = Double(Float(number)) }
            try require(number.isFinite, "non-finite fixed-scale floating-point default")
            // MySQL's fixed-format default metadata represents this stored
            // value. Compare its numeric presentation, not padding or row bits.
            let displayed = String(format: "%.*f", type.arguments[1], number)
            let canonical = Double(displayed)!
            return canonical == 0 ? "0.0" : String(canonical)
        }
        if type.floatingWidth == 32 {
            number = min(max(number, -Double(Float.greatestFiniteMagnitude)), Double(Float.greatestFiniteMagnitude))
            let value = Float(number)
            // Field_float::val_str / my_gcvt displays FLT_DIG (six significant
            // digits). Compare that presentation only, not the stored IEEE bits.
            // Do not reject or rewrite the original default for lost digits.
            let displayed = String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), Double(value))
            let canonical = Double(displayed)!
            return canonical == 0 ? "0.0" : String(canonical)
        }
        return number == 0 ? "0.0" : String(number)
    }
}
