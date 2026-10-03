import Foundation
import ReplicatorCodec

/// Types qualified for prepared-table DML on MySQL 5.7. DDL has its own grammar.
struct DMLColumnType {
    let base: String
    let arguments: [Int]
    let unsigned: Bool
    let integerBits: Int?
    let labels: [Data]
    var isChoice: Bool { base == "enum" || base == "set" }
    var isText: Bool { base == "char" || base == "varchar" || base.hasSuffix("text") || isChoice }
    init(_ definition: String) throws {
        if definition.hasPrefix("enum(") || definition.hasPrefix("set(") {
            base = definition.hasPrefix("enum(") ? "enum" : "set"
            unsigned = false; integerBits = nil; arguments = []
            labels = try Self.parseLabels(definition,base:base)
            try require((1...(base == "enum" ? 65535 : 64)).contains(labels.count),"invalid ENUM/SET label count")
            return
        }
        labels = []
        unsigned = definition.hasSuffix(" unsigned")
        let type = unsigned ? String(definition.dropLast(9)) : definition
        let parts = type.split(separator:"(",omittingEmptySubsequences:false)
        base = String(parts[0])
        if parts.count == 2, parts[1].hasSuffix(")") {
            let words = parts[1].dropLast().split(separator:",",omittingEmptySubsequences:false)
            arguments = try words.map { word in
                guard !word.isEmpty, word.utf8.allSatisfy({(48...57).contains($0)}), let n=Int(word) else {throw ApplyError("invalid column type arguments")}
                return n
            }
        } else { try require(parts.count == 1,"invalid column type"); arguments=[] }
        integerBits = ["tinyint":8,"smallint":16,"mediumint":24,"int":32,"bigint":64][base]
        if integerBits != nil { try require(arguments.isEmpty,"integer display width must be normalized"); return }
        try require(!unsigned || base == "decimal","unsupported unsigned column type")
        switch base {
        case "char","binary": try require(arguments.count == 1 && (0...255).contains(arguments[0]),"unsupported fixed column width")
        case "varchar","varbinary": try require(arguments.count == 1 && (1...16383).contains(arguments[0]),"unsupported declared column type")
        case "tinytext","text","mediumtext","longtext","tinyblob","blob","mediumblob","longblob","date","year":
            try require(arguments.isEmpty,"unsupported column type arguments")
        case "decimal": try require(arguments.count == 2 && (1...65).contains(arguments[0]) && (0...min(30,arguments[0])).contains(arguments[1]),"unsupported DECIMAL precision/scale")
        case "time","datetime","timestamp": try require(arguments.isEmpty || (arguments.count == 1 && (0...6).contains(arguments[0])),"unsupported temporal precision")
        default: throw ApplyError("unsupported declared column type for MySQL 5.7 apply: " + definition)
        }
    }
    private static func parseLabels(_ definition: String, base: String) throws -> [Data] {
        let bytes=Array(definition.utf8); var index=base.utf8.count+1, result:[Data]=[]
        while index < bytes.count {
            try require(bytes[index] == 39,"invalid ENUM/SET label")
            index += 1; var value=Data(), closed=false
            while index < bytes.count {
                let byte=bytes[index]; index += 1
                if byte == 39 {
                    if index < bytes.count && bytes[index] == 39 { value.append(39); index += 1 }
                    else { closed=true; break }
                } else if byte == 92 {
                    try require(index < bytes.count,"truncated ENUM/SET escape")
                    let escaped=bytes[index]; index += 1
                    guard let decoded:[UInt8] = [48:[0],110:[10],114:[13],92:[92]][escaped] else { throw ApplyError("unsupported ENUM/SET metadata escape") }
                    value.append(contentsOf:decoded)
                } else { value.append(byte) }
            }
            try require(closed,"unterminated ENUM/SET label")
            result.append(value)
            try require(index < bytes.count,"unterminated ENUM/SET definition")
            let separator=bytes[index]; index += 1
            if separator == 41 { try require(index == bytes.count,"trailing ENUM/SET definition"); return result }
            try require(separator == 44,"invalid ENUM/SET separator")
        }
        throw ApplyError("unterminated ENUM/SET definition")
    }
    var interpretation: ColumnInterpretation {
        if isChoice { return .unsigned }
        if integerBits != nil { return unsigned ? .unsigned : .signed }
        if base == "decimal" { return .decimal }
        if base == "char" || base == "varchar" || base.hasSuffix("text") { return .utf8 }
        if base == "binary" || base == "varbinary" || base.hasSuffix("blob") { return .binary }
        return .temporal
    }
    var maximumBytes: Int? {
        switch base {
        case "char","varchar": return arguments[0]*4
        case "binary","varbinary": return arguments[0]
        case "tinytext","tinyblob": return 255
        case "text","blob": return 65535
        case "mediumtext","mediumblob": return 16777215
        case "longtext","longblob": return 4294967295
        default: return nil
        }
    }
    var fraction: Int { arguments.first ?? 0 }
    func matches(_ wire: WireColumn) -> Bool {
        let code = wire.type, meta = Array(wire.metadata)
        if integerBits != nil {
            return code == ["tinyint":1,"smallint":2,"mediumint":9,"int":3,"bigint":8][base] && wire.interpretation == interpretation
        }
        switch base {
        case "enum","set":
            return code == (base == "enum" ? 247 : 248) && wire.interpretation == .unsigned && meta.count == 2 && Int(meta[1]) == (base == "enum" ? (labels.count < 256 ? 1 : 2) : (labels.count+7)/8)
        case "char","binary": return code == 254 && wire.interpretation == interpretation && wire.maximumBytes == UInt32(maximumBytes!)
        case "varchar","varbinary": return (code == 15 || code == 253) && wire.interpretation == interpretation && wire.maximumBytes == UInt32(maximumBytes!)
        case "tinytext","tinyblob","text","blob","mediumtext","mediumblob","longtext","longblob":
            let bytes: UInt8 = base.hasPrefix("tiny") ? 1 : base.hasPrefix("medium") ? 3 : base.hasPrefix("long") ? 4 : 2
            return code == 252 && wire.interpretation == interpretation && meta == [bytes]
        case "decimal": return code == 246 && meta == arguments.map(UInt8.init) && wire.isUnsigned == unsigned
        case "date": return code == 10 || code == 14
        case "year": return code == 13
        case "time","datetime","timestamp": return code == ["time":19,"datetime":18,"timestamp":17][base] && meta == [UInt8(fraction)]
        default: return false
        }
    }
    func validate(_ value: DecodedValue) throws {
        if isChoice {
            guard case .unsigned(let n) = value else { throw ApplyError("ENUM/SET requires an ordinal or bitmask") }
            try require(base == "enum" ? (n > 0 && n <= UInt64(labels.count)) : (labels.count == 64 || n < (UInt64(1) << labels.count)),"ENUM/SET value out of range")
            return
        }
        switch (interpretation,value) {
        case (.signed,.signed(let n)):
            let bits=integerBits!
            if bits < 64 { let half=Int64(1) << (bits-1); try require((-half..<half).contains(n),"signed value out of range") }
        case (.unsigned,.unsigned(let n)):
            if integerBits! < 64 { try require(n < UInt64(1) << integerBits!,"unsigned value out of range") }
        case (.utf8,.text(let s)):
            try require(s.utf8.count <= maximumBytes!,"text value exceeds declared length")
            if base == "varchar" || base == "char" { try require(s.unicodeScalars.count <= arguments[0],"varchar value exceeds declared length") }
        case (.binary,.binary(let data)): try require(base == "binary" ? data.count == maximumBytes! : data.count <= maximumBytes!,"binary value differs from declared length")
        case (.decimal,.decimal(let s)):
            try require(s.range(of:#"^-?[0-9]+(?:\.[0-9]+)?$"#,options:.regularExpression) != nil,"invalid exact decimal")
            let digits=s.hasPrefix("-") ? String(s.dropFirst()) : s
            let parts=digits.split(separator:".",omittingEmptySubsequences:false)
            let integral=parts[0].drop(while:{$0 == "0"}).count
            try require(integral <= arguments[0]-arguments[1] && (parts.count == 2 ? parts[1].count : 0) == arguments[1] && (!unsigned || !s.hasPrefix("-")),"decimal value exceeds declared precision/scale")
        case (.temporal,.temporal(let s)): _ = try canonicalTemporal(s)
        default: throw ApplyError("missing or incompatible full row value")
        }
    }
    /// CAST(... AS CHAR) avoids driver calendar/Double conversion and preserves negative TIME.
    /// Normalize MySQL's precision-specific text to the decoder's six-digit fractions.
    func canonicalTemporal(_ text: String) throws -> String {
        if base == "date" {
            try require(text.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,options:.regularExpression) != nil,"invalid DATE representation")
            return text
        }
        if base == "year" {
            guard let year=Int(text),year == 0 || (1901...2155).contains(year) else {throw ApplyError("invalid YEAR representation")}
            return String(format:"%04d",year)
        }
        let pattern = base == "time" ? #"^-?[0-9]{2,3}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$"# : #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$"#
        try require(text.range(of:pattern,options:.regularExpression) != nil,"invalid temporal representation")
        let parts=text.split(separator:".",omittingEmptySubsequences:false)
        let micros=parts.count == 2 ? String(parts[1]) : ""
        let padded=micros + String(repeating:"0",count:6-micros.count)
        try require(padded.dropFirst(fraction).allSatisfy{$0 == "0"},"temporal value exceeds declared precision")
        let result=String(parts[0])+"."+padded
        if base == "time" {
            let clock=parts[0].split(separator:":").map{Int($0)!}
            let hours=abs(clock[0])
            try require(hours <= 838 && clock[1] < 60 && clock[2] < 60 && (hours < 838 || clock[1] < 59 || clock[2] < 59 || padded == "000000"),"TIME exceeds MySQL 5.7 range")
        }
        if base == "timestamp" {
            try require(result == "0000-00-00 00:00:00.000000" || (result >= "1970-01-01 00:00:01.000000" && result <= "2038-01-19 03:14:07.999999"),"TIMESTAMP exceeds MySQL 5.7 range")
        }
        return result
    }
}
