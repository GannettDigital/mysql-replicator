import Foundation
import ReplicatorCodec

/// Types qualified for prepared-table DML on MySQL 5.7. DDL has its own grammar.
struct DMLColumnType {
    let characterSet: String
    let base: String
    let arguments: [Int]
    let unsigned: Bool
    let zerofill: Bool
    let integerBits: Int?
    let labels: [Data]
    static let spatialTypes = [
        "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
        "geometrycollection",
    ]
    var geometryType: UInt32? { Self.spatialTypes.firstIndex(of: base).map(UInt32.init) }
    var isSpatial: Bool { geometryType != nil }
    var floatingWidth: Int? { base == "float" ? 32 : base == "double" ? 64 : nil }
    var bitWidth: Int? { base == "bit" ? (arguments.first ?? 1) : nil }
    var isChoice: Bool { base == "enum" || base == "set" }
    var isText: Bool { base == "char" || base == "varchar" || base.hasSuffix("text") || isChoice }
    init(_ column: ApplyColumn) throws {
        try self.init(
            column.type,
            characterSet: column.characterSet ?? CharacterSetRegistry.columnCollation(named: column.collation ?? "")?
                .characterSet ?? "utf8mb4", choiceLabels: column.choiceLabels)
    }
    init(_ definition: String, characterSet: String = "utf8mb4", choiceLabels: [Data]? = nil) throws {
        self.characterSet = CharacterSetRegistry.canonicalCharset(characterSet)
        if definition.hasPrefix("enum(") || definition.hasPrefix("set(") {
            base = definition.hasPrefix("enum(") ? "enum" : "set"
            unsigned = false
            zerofill = false
            integerBits = nil
            arguments = []
            let displayed = try Self.parseLabels(definition, base: base)
            try require(
                choiceLabels == nil || choiceLabels!.count == displayed.count, "ENUM/SET encoded label count differs")
            labels = choiceLabels ?? displayed
            try require((1...(base == "enum" ? 65535 : 64)).contains(labels.count), "invalid ENUM/SET label count")
            return
        }
        try require(choiceLabels == nil, "encoded labels on a non-ENUM/SET column")
        labels = []
        zerofill = definition.hasSuffix(" zerofill")
        let numeric = zerofill ? String(definition.dropLast(9)) : definition
        unsigned = numeric.hasSuffix(" unsigned") || zerofill
        let type = numeric.hasSuffix(" unsigned") ? String(numeric.dropLast(9)) : numeric
        let parts = type.split(separator: "(", omittingEmptySubsequences: false)
        base = String(parts[0])
        if parts.count == 2, parts[1].hasSuffix(")") {
            let words = parts[1].dropLast().split(separator: ",", omittingEmptySubsequences: false)
            arguments = try words.map { word in
                guard !word.isEmpty, word.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(word) else {
                    throw ApplyError("invalid column type arguments")
                }
                return n
            }
        } else {
            try require(parts.count == 1, "invalid column type")
            arguments = []
        }
        integerBits = ["tinyint": 8, "smallint": 16, "mediumint": 24, "int": 32, "bigint": 64][base]
        if integerBits != nil {
            try require(
                arguments.isEmpty || (zerofill && arguments.count == 1 && (1...255).contains(arguments[0])),
                "integer display width must be normalized unless ZEROFILL needs it")
            return
        }
        try require(!unsigned || base == "decimal" || floatingWidth != nil, "unsupported unsigned column type")
        if isSpatial {
            try require(arguments.isEmpty, "spatial types have no type arguments")
            return
        }
        switch base {
        case "float", "double":
            try require(
                arguments.isEmpty
                    || (arguments.count == 2 && (1...255).contains(arguments[0]) && (0...30).contains(arguments[1])
                        && arguments[1] <= arguments[0]),
                "invalid floating-point width/scale")
        case "bit":
            try require(
                arguments.isEmpty || (arguments.count == 1 && (1...64).contains(arguments[0])), "invalid BIT width")
        case "char", "binary":
            try require(arguments.count == 1 && (0...255).contains(arguments[0]), "unsupported fixed column width")
        case "varchar", "varbinary":
            try require(arguments.count == 1 && (0...65535).contains(arguments[0]), "unsupported declared column type")
        case "tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob", "date", "year",
            "json":
            try require(arguments.isEmpty, "unsupported column type arguments")
        case "decimal":
            try require(
                arguments.count == 2 && (1...65).contains(arguments[0])
                    && (0...min(30, arguments[0])).contains(arguments[1]), "unsupported DECIMAL precision/scale")
        case "time", "datetime", "timestamp":
            try require(
                arguments.isEmpty || (arguments.count == 1 && (0...6).contains(arguments[0])),
                "unsupported temporal precision")
        default: throw ApplyError("unsupported declared column type for MySQL 5.7 apply: " + definition)
        }
    }
    private static func parseLabels(_ definition: String, base: String) throws -> [Data] {
        let bytes = Array(definition.utf8)
        var index = base.utf8.count + 1
        var result: [Data] = []
        while index < bytes.count {
            var value = Data()
            var closed = false
            if bytes[index] == 88 || bytes[index] == 120 {
                index += 1
                try require(index < bytes.count && bytes[index] == 39, "invalid hexadecimal ENUM/SET label")
                index += 1
                let start = index
                while index < bytes.count && bytes[index] != 39 { index += 1 }
                try require(index < bytes.count, "unterminated hexadecimal ENUM/SET label")
                value = try SQLByteLiteral.decode(
                    String(decoding: bytes[start..<index], as: UTF8.self), radix: 16, allowOdd: false)
                index += 1
                closed = true
            } else {
                try require(bytes[index] == 39, "invalid ENUM/SET label")
                index += 1
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 39 {
                        if index < bytes.count && bytes[index] == 39 {
                            value.append(39)
                            index += 1
                        } else {
                            closed = true
                            break
                        }
                    } else if byte == 92 {
                        try require(index < bytes.count, "truncated ENUM/SET escape")
                        let escaped = bytes[index]
                        index += 1
                        guard let decoded: [UInt8] = [48: [0], 110: [10], 114: [13], 92: [92]][escaped] else {
                            throw ApplyError("unsupported ENUM/SET metadata escape")
                        }
                        value.append(contentsOf: decoded)
                    } else {
                        value.append(byte)
                    }
                }
            }
            try require(closed, "unterminated ENUM/SET label")
            result.append(value)
            try require(index < bytes.count, "unterminated ENUM/SET definition")
            let separator = bytes[index]
            index += 1
            if separator == 41 {
                try require(index == bytes.count, "trailing ENUM/SET definition")
                return result
            }
            try require(separator == 44, "invalid ENUM/SET separator")
        }
        throw ApplyError("unterminated ENUM/SET definition")
    }
    var interpretation: ColumnInterpretation {
        if isSpatial { return .binary }
        if base == "json" { return .json }
        if let width = floatingWidth { return width == 32 ? .float32 : .float64 }
        if isChoice || bitWidth != nil { return .unsigned }
        if integerBits != nil { return unsigned ? .unsigned : .signed }
        if base == "decimal" { return .decimal }
        if base == "char" || base == "varchar" || base.hasSuffix("text") {
            switch characterSet {
            case "utf8mb3", "utf8mb4": return .utf8
            case "ucs2", "utf16": return .encodedText16BE
            case "utf16le": return .encodedText16LE
            case "utf32": return .encodedText32BE
            default: return .encodedText
            }
        }
        if base == "binary" || base == "varbinary" || base.hasSuffix("blob") { return .binary }
        return .temporal
    }
    var maximumBytes: Int? {
        if isSpatial { return 4_294_967_295 }
        switch base {
        case "char", "varchar": return arguments[0] * CharacterSetRegistry.maximumBytesPerCharacter(characterSet)
        case "binary", "varbinary": return arguments[0]
        case "tinytext", "tinyblob": return 255
        case "text", "blob": return 65535
        case "mediumtext", "mediumblob": return 16_777_215
        case "longtext", "longblob": return 4_294_967_295
        default: return nil
        }
    }
    func sqlValue(_ expression: String) -> String {
        interpretation.isEncodedText ? "CONVERT(\(expression) USING \(characterSet))" : expression
    }
    func sqlKeyColumn(_ name: String) -> String {
        // UPDATE/DELETE range analysis can discard a rounded FLOAT endpoint
        // even when SELECT finds it. Compare the promoted stored value to the
        // binary parameter. This may require a scan for fixed-scale FLOAT keys.
        base == "float" && arguments.count == 2 ? "(\(name)+0e0)" : name
    }
    func sqlWriteValue(_ expression: String) -> String {
        // FLOAT may round a legal decimal endpoint outward. A binary SQL
        // parameter then fails strict range checks, although native row apply
        // copies it. Bound only the SQL input; the target stores the same FLOAT
        // bits. Predicates must still use the original stored key value.
        if base == "float", arguments.count == 2, arguments[0] - arguments[1] <= 38 {
            let whole = arguments[0] - arguments[1]
            let scale = arguments[1]
            let limit =
                (whole == 0 ? "0" : String(repeating: "9", count: whole))
                + (scale == 0 ? "" : "." + String(repeating: "9", count: scale))
            return "LEAST(GREATEST(\(expression),\(unsigned ? "0" : "-"+limit)),\(limit))"
        }
        return sqlValue(expression)
    }
    var fraction: Int { arguments.first ?? 0 }
    func matches(_ wire: WireColumn, legacyMetadata: Bool = false) -> Bool {
        let code = wire.type
        let meta = Array(wire.metadata)
        let matchingInterpretation =
            wire.interpretation == interpretation || (legacyMetadata && wire.interpretation == nil)
        if let geometryType {
            return code == 255 && meta == [4] && matchingInterpretation
                && (wire.geometryType == nil || wire.geometryType == geometryType)
        }
        if integerBits != nil {
            return code == ["tinyint": 1, "smallint": 2, "mediumint": 9, "int": 3, "bigint": 8][base]
                && matchingInterpretation
        }
        switch base {
        case "json": return code == 245 && matchingInterpretation && meta == [4]
        case "float", "double":
            return code == (base == "float" ? 4 : 5) && matchingInterpretation && meta == [UInt8(floatingWidth! / 8)]
                && (wire.isUnsigned == unsigned || (legacyMetadata && wire.isUnsigned == nil))
        case "bit":
            return code == 16 && wire.interpretation == .unsigned
                && meta == [UInt8(bitWidth! % 8), UInt8(bitWidth! / 8)]
        case "enum", "set":
            return code == (base == "enum" ? 247 : 248) && wire.interpretation == .unsigned && meta.count == 2
                && Int(meta[1]) == (base == "enum" ? (labels.count < 256 ? 1 : 2) : (labels.count + 7) / 8)
        case "char", "binary":
            return code == 254 && matchingInterpretation && wire.maximumBytes == UInt32(maximumBytes!)
        case "varchar", "varbinary":
            return (code == 15 || code == 253) && matchingInterpretation && wire.maximumBytes == UInt32(maximumBytes!)
        case "tinytext", "tinyblob", "text", "blob", "mediumtext", "mediumblob", "longtext", "longblob":
            let bytes: UInt8 =
                base.hasPrefix("tiny") ? 1 : base.hasPrefix("medium") ? 3 : base.hasPrefix("long") ? 4 : 2
            return code == 252 && matchingInterpretation && meta == [bytes]
        case "decimal":
            return code == 246 && meta == arguments.map(UInt8.init)
                && (wire.isUnsigned == unsigned || (legacyMetadata && wire.isUnsigned == nil))
        case "date": return code == 10 || code == 14
        case "year": return code == 13
        case "time", "datetime", "timestamp":
            return code == ["time": 19, "datetime": 18, "timestamp": 17][base] && meta == [UInt8(fraction)]
        default: return false
        }
    }
    func validate(_ value: DecodedValue) throws {
        if let width = bitWidth {
            guard case .unsigned(let n) = value else { throw ApplyError("BIT requires an unsigned value") }
            try require(width == 64 || n < (UInt64(1) << width), "BIT value exceeds declared width")
            return
        }
        if isChoice {
            guard case .unsigned(let n) = value else { throw ApplyError("ENUM/SET requires an ordinal or bitmask") }
            try require(
                base == "enum" ? (n <= UInt64(labels.count)) : (labels.count == 64 || n < (UInt64(1) << labels.count)),
                "ENUM/SET value out of range")
            return
        }
        switch (interpretation, value) {
        case (.json, .json): break
        case (.signed, .signed(let n)):
            let bits = integerBits!
            if bits < 64 {
                let half = Int64(1) << (bits - 1)
                try require((-half..<half).contains(n), "signed value out of range")
            }
        case (.unsigned, .unsigned(let n)):
            if integerBits! < 64 { try require(n < UInt64(1) << integerBits!, "unsigned value out of range") }
        case (.encodedText, .binary(let bytes)), (.encodedText16BE, .binary(let bytes)),
            (.encodedText16LE, .binary(let bytes)), (.encodedText32BE, .binary(let bytes)):
            try require(bytes.count <= maximumBytes!, "text bytes exceed declared length")
            let unit =
                interpretation == .encodedText32BE
                ? 4 : (interpretation == .encodedText16BE || interpretation == .encodedText16LE) ? 2 : 1
            try require(bytes.count % unit == 0, "partial encoded character")
            if characterSet == "ascii" { try require(bytes.allSatisfy { $0 < 128 }, "non-ASCII text bytes") }
        case (.utf8, .text(let s)):
            if characterSet == "utf8mb3" {
                try require(s.unicodeScalars.allSatisfy { $0.value <= 0xffff }, "four-byte character in utf8mb3 column")
            }
            try require(s.utf8.count <= maximumBytes!, "text value exceeds declared length")
            if base == "varchar" || base == "char" {
                try require(s.unicodeScalars.count <= arguments[0], "varchar value exceeds declared length")
            }
        case (.binary, .binary(let data)):
            try require(
                base == "binary" ? data.count == maximumBytes! : data.count <= maximumBytes!,
                "binary value differs from declared length")
        case (.decimal, .decimal(let s)):
            try require(
                s.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil, "invalid exact decimal")
            let digits = s.hasPrefix("-") ? String(s.dropFirst()) : s
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            let integral = parts[0].drop(while: { $0 == "0" }).count
            try require(
                integral <= arguments[0] - arguments[1] && (parts.count == 2 ? parts[1].count : 0) == arguments[1]
                    && (!unsigned || !s.hasPrefix("-")), "decimal value exceeds declared precision/scale")
        case (.float32, .float32(let bits)):
            let n = Float(bitPattern: bits)
            try require(n.isFinite && (!unsigned || n >= 0), "non-finite or negative unsigned FLOAT")
            if arguments.count == 2 {
                let limit = Float(pow(10.0, Double(arguments[0] - arguments[1])) - pow(10.0, -Double(arguments[1])))
                try require(abs(n) <= limit, "FLOAT exceeds stored fixed-scale range")
            }
        case (.float64, .float64(let bits)):
            let n = Double(bitPattern: bits)
            try require(n.isFinite && (!unsigned || n >= 0), "non-finite or negative unsigned DOUBLE")
        case (.temporal, .temporal(let s)): _ = try canonicalTemporal(s)
        default: throw ApplyError("missing or incompatible full row value")
        }
    }
    /// CAST(... AS CHAR) avoids driver calendar/Double conversion and preserves negative TIME.
    /// Normalize MySQL's precision-specific text to the decoder's six-digit fractions.
    func canonicalTemporal(_ text: String) throws -> String {
        if base == "date" {
            try require(
                text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                "invalid DATE representation")
            return text
        }
        if base == "year" {
            guard let year = Int(text), year == 0 || (1901...2155).contains(year) else {
                throw ApplyError("invalid YEAR representation")
            }
            return String(format: "%04d", year)
        }
        let pattern =
            base == "time"
            ? #"^-?[0-9]{2,3}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$"#
            : #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$"#
        try require(text.range(of: pattern, options: .regularExpression) != nil, "invalid temporal representation")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let micros = parts.count == 2 ? String(parts[1]) : ""
        let padded = micros + String(repeating: "0", count: 6 - micros.count)
        try require(padded.dropFirst(fraction).allSatisfy { $0 == "0" }, "temporal value exceeds declared precision")
        let result = String(parts[0]) + "." + padded
        if base == "time" {
            let clock = parts[0].split(separator: ":").map { Int($0)! }
            let hours = abs(clock[0])
            try require(
                hours <= 838 && clock[1] < 60 && clock[2] < 60
                    && (hours < 838 || clock[1] < 59 || clock[2] < 59 || padded == "000000"),
                "TIME exceeds MySQL 5.7 range")
        }
        if base == "timestamp" {
            try require(
                result == "0000-00-00 00:00:00.000000"
                    || (result >= "1970-01-01 00:00:01.000000" && result <= "2038-01-19 03:14:07.999999"),
                "TIMESTAMP exceeds MySQL 5.7 range")
        }
        return result
    }
}
