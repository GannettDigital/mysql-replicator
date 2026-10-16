import Foundation

/// Independent test oracle for native SHOW CREATE bytes. Do not use the applier's
/// type parser: 5.7 can emit raw non-UTF8 bytes and 8.4 can emit hex literals.
struct NativeChoiceDefinition:Equatable {
    let type:String
    let defaultValue:String
    static func read(_ data:Data,column:String) throws -> Self {
        let prefix=Array(("  `"+column.replacingOccurrences(of:"`",with:"``")+"` ").utf8)
        guard let line=data.split(separator:10).first(where: { $0.starts(with:prefix) }) else { throw LabError("native SHOW CREATE lacks choice column "+column) }
        var parser=Parser(bytes:Array(line.dropFirst(prefix.count)))
        let base:String
        if parser.take("enum(") { base="enum" }
        else { try require(parser.take("set("),"native choice column type differs");base="set" }
        var labels:[Data]=[]
        repeat { labels.append(try parser.literal()) } while parser.take(",")
        try require(parser.take(")"),"native choice labels are incomplete")
        let tail=Data(parser.bytes[parser.index...])
        var value="<NULL>"
        if let range=tail.range(of:Data(" DEFAULT ".utf8)) {
            var defaults=Parser(bytes:Array(tail[range.upperBound...]))
            if !defaults.take("NULL") { value=hex(try defaults.literal()) }
        }
        return .init(type:base+"("+labels.map(hex).joined(separator:",")+")",defaultValue:value)
    }
    /// Single binary-column fixtures. Read bounds independently of the applier.
    static func partitionBounds(_ data:Data,partition:String) throws -> String {
        try require(partition.range(of:#"^[A-Za-z_][A-Za-z0-9_]*$"#,options:.regularExpression) != nil,"unsupported fixture partition name")
        let prefix=Data(("PARTITION "+partition+" VALUES ").utf8)
        guard let range=data.range(of:prefix) else {throw LabError("missing native partition bounds")}
        var parser=Parser(bytes:Array(data[range.upperBound...]))
        try require(parser.take("LESS THAN") || parser.take("IN"),"unexpected native bound syntax")
        _ = parser.take(" ")
        try require(parser.take("("),"missing native bound list")
        var values:[String]=[]
        repeat {
            if parser.take("MAXVALUE") {values.append("MAXVALUE")}
            else if parser.take("NULL") {values.append("NULL")}
            else {
                _ = parser.take("_binary ")
                values.append(hex(try parser.literal()))
            }
        } while parser.take(",")
        try require(parser.take(")"),"incomplete native partition bounds")
        return values.joined(separator:",")
    }
    private static func hex(_ bytes:Data) -> String { "X'"+bytes.map { String(format:"%02x",$0) }.joined()+"'" }
    private struct Parser {
        let bytes:[UInt8]
        var index=0
        mutating func take(_ text:String) -> Bool {
            let token=Array(text.utf8)
            guard bytes[index...].starts(with:token) else { return false }
            index += token.count;return true
        }
        mutating func literal() throws -> Data {
            if take("x'") || take("X'") || take("0x") || take("0X") {
                let quoted=bytes[index-1] == 39,start=index
                while index < bytes.count && ((48...57).contains(bytes[index]) || (65...70).contains(bytes[index]) || (97...102).contains(bytes[index])) { index += 1 }
                let digits=Array(bytes[start..<index])
                try require(digits.count % 2 == 0,"odd native hex literal")
                if quoted { try require(take("'"),"unterminated native hex literal") }
                return Data(try stride(from:0,to:digits.count,by:2).map { offset in
                    guard let byte=UInt8(String(decoding:digits[offset..<offset+2],as:UTF8.self),radix:16) else { throw LabError("invalid native hex literal") };return byte
                })
            }
            try require(take("'"),"missing native byte literal")
            var result=Data()
            while index < bytes.count {
                let byte=bytes[index];index += 1
                if byte == 39 {
                    if take("'") { result.append(39) } else { return result }
                } else if byte == 92 {
                    try require(index < bytes.count,"incomplete native escape")
                    let next=bytes[index];index += 1
                    result.append([UInt8(48):0,110:10,114:13,92:92][next] ?? next)
                } else { result.append(byte) }
            }
            throw LabError("unterminated native byte literal")
        }
    }
}
