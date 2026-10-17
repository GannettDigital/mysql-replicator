import Foundation

public struct JSONTypedScalar: Codable, Equatable {
    public let type: Int
    public let value: String
    public let rawHex: String
    public let precision: Int
    public let scale: Int
    public var rawBytes: Data {
        let b=Array(rawHex.utf8)
        return Data(stride(from:0,to:b.count,by:2).map { UInt8(String(decoding:b[$0..<$0+2],as:UTF8.self),radix:16)! })
    }
    public var typeName: String {
        switch type {
        case 1000: return "INTEGER"
        case 1001: return "UNSIGNED INTEGER"
        case 246: return "DECIMAL"
        case 10: return "DATE"
        case 11: return "TIME"
        case 12: return "DATETIME"
        case 7: return "TIMESTAMP"
        case 16: return "BIT"
        case 255: return "GEOMETRY"
        case 15,249,250,251,252,253,254: return "BLOB"
        default: return "OPAQUE"
        }
    }
    public var display: String {
        guard ![1000,1001,246,7,10,11,12].contains(type) else { return value }
        // MySQL base64 output wraps at 76 columns.
        let base64=Array(rawBytes.base64EncodedString().utf8)
        let wrapped=stride(from:0,to:base64.count,by:76).map { String(decoding:base64[$0..<min($0+76,base64.count)],as:UTF8.self) }.joined(separator:"\n")
        return "base64:type\(type):"+wrapped
    }
    func validate() throws {
        try jsonRequire(rawHex.utf8.count % 2 == 0 && rawHex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) },"invalid typed JSON bytes")
        switch type {
        case 1000: try jsonRequire(Int64(value) != nil,"invalid signed JSON integer")
        case 1001: try jsonRequire(UInt64(value) != nil,"invalid unsigned JSON integer")
        case 246: try jsonRequire((1...81).contains(precision) && (0...min(precision,30)).contains(scale) && (precision-scale+8)/9+(scale+8)/9 <= 9 && value.range(of:#"^-?[0-9]+(?:\.[0-9]+)?$"#,options:.regularExpression) != nil,"invalid JSON decimal")
        case 7,10,11,12: try jsonRequire(rawBytes.count == 8,"invalid JSON temporal bytes")
        default: try jsonRequire((0...255).contains(type),"invalid JSON opaque type")
        }
    }
}
public struct JSONTypedValue: Encodable {
    public let path: String
    public let scalar: JSONTypedScalar
}
public struct JSONScalarCheck {
    public let path: String
    public let type: String
}
struct JSONEnvelope: Decodable {
    struct Typed: Decodable { let path: String; let type: Int; let value: String; let rawHex: String; let precision: Int; let scale: Int }
    let text: String
    let typed: [Typed]
}

/// Exact source values plus a JSON text template. Typed leaves occupy null slots
/// in the template. SQL construction restores them with typed expressions.
public struct JSONDocument: Equatable {
    let root: JSONNode
    public let text: String
    public let typedValues: [JSONTypedValue]
    public let scalarChecks: [JSONScalarCheck]
    public let retainedByteCost: Int
    init(root: JSONNode) throws {
        self.root=root
        text=try root.render()
        var typed:[JSONTypedValue]=[], checks:[JSONScalarCheck]=[], cost=0
        try root.walk(path:"$",depth:1) { node,path in
            cost += 128+path.utf8.count
            if case .typed(let s)=node { typed.append(.init(path:path,scalar:s)); cost += s.rawHex.utf8.count+s.value.utf8.count }
            if let type=node.typeName { checks.append(.init(path:path,type:type)) }
        }
        typedValues=typed; scalarChecks=checks; retainedByteCost=cost+text.utf8.count*2
    }
    public init(text: String) throws {
        var parser=JSONDocumentParser(bytes:Array(text.utf8))
        let root=try parser.value(depth:1)
        parser.space(); try jsonRequire(parser.index == parser.bytes.count,"trailing JSON text")
        try self.init(root:root)
    }
    init(envelope: JSONEnvelope) throws {
        var root=try JSONDocument(text:envelope.text).root
        var paths=Set<Data>()
        for t in envelope.typed {
            try jsonRequire(paths.insert(Data(t.path.utf8)).inserted,"duplicate typed JSON path")
            let value=JSONTypedScalar(type:t.type,value:t.value,rawHex:t.rawHex,precision:t.precision,scale:t.scale)
            try value.validate()
            let path=try JSONPath.parse(t.path)
            try root.change(path[...],operation:0,value:.typed(value),requireNull:true)
        }
        try self.init(root:root)
    }
    init(source: Data) throws { try self.init(envelope:JSONDecoder().decode(JSONEnvelope.self,from:source)) }
    /// Build a target view without changing source bytes retained for replay/recovery.
    /// The caller must explicitly select the cross-version compatibility policy.
    public func convertingOpaqueYearsToIntegers() throws -> JSONDocument {
        let years=typedValues.filter { $0.scalar.type == 13 }
        guard !years.isEmpty else { return self }
        var converted=root
        for entry in years {
            let bytes=entry.scalar.rawBytes
            guard !bytes.isEmpty, bytes.count <= 4, bytes.allSatisfy({ (48...57).contains($0) }),
                  let year=UInt16(String(decoding:bytes,as:UTF8.self)),
                  year == 0 || (1901...2155).contains(year) else {
                throw DecoderError(code:2,offset:0,reason:"invalid JSON YEAR bytes at \(entry.path)")
            }
            let scalar=JSONTypedScalar(type:1001,value:String(year),rawHex:"",precision:0,scale:0)
            let path=try JSONPath.parse(entry.path)
            try converted.change(path[...],operation:0,value:.typed(scalar))
        }
        return try JSONDocument(root:converted)
    }
    public static func == (lhs: Self,rhs: Self) -> Bool { lhs.root.same(rhs.root) }
    /// Caller must also check scalarChecks against target JSON_TYPE results.
    public func matchesTargetText(_ text: String) throws -> Bool {
        var parser=JSONDocumentParser(bytes:Array(text.utf8),rawNumbers:true)
        let actual=try parser.value(depth:1); parser.space()
        try jsonRequire(parser.index == parser.bytes.count,"trailing target JSON text")
        return root.matchesDisplay(actual)
    }
}
func jsonRequire(_ valid: Bool,_ reason: String) throws {
    if !valid { throw DecoderError(code:2,offset:0,reason:reason) }
}
func jsonQuote(_ string: String) throws -> String { String(decoding:try JSONEncoder().encode(string),as:UTF8.self) }
indirect enum JSONNode {
    case null, bool(Bool), number(String), string(String), array([JSONNode]), object([Data:JSONNode]), typed(JSONTypedScalar)
    var typeName: String? {
        switch self {
        case .null: return "NULL"
        case .bool: return "BOOLEAN"
        case .number(let n): return n.contains(".") || n.lowercased().contains("e") ? "DOUBLE" : (Int64(n) == nil ? "UNSIGNED INTEGER" : "INTEGER")
        case .string: return "STRING"
        case .typed(let s): return s.typeName
        case .array,.object: return nil
        }
    }
    func render() throws -> String {
        switch self {
        case .null,.typed: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return try jsonQuote(s)
        case .array(let a): return "["+(try a.map { try $0.render() }.joined(separator:","))+"]"
        case .object(let o): return "{"+(try o.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { try jsonQuote(String(decoding:$0,as:UTF8.self))+":"+o[$0]!.render() }.joined(separator:","))+"}"
        }
    }
    func walk(path:String,depth:Int,visit:(JSONNode,String)throws->Void) throws {
        try jsonRequire(depth <= 100,"JSON depth exceeds 100")
        try visit(self,path)
        switch self {
        case .array(let a): for (i,n) in a.enumerated() { try n.walk(path:path+"[\(i)]",depth:depth+1,visit:visit) }
        case .object(let o): for key in o.keys.sorted(by:{$0.lexicographicallyPrecedes($1)}) { try o[key]!.walk(path:path+"."+jsonQuote(String(decoding:key,as:UTF8.self)),depth:depth+1,visit:visit) }
        default: break
        }
    }
    func same(_ other: JSONNode) -> Bool {
        if case .typed(let s)=self, [1000,1001].contains(s.type), case .number(let n)=other { return s.typeName == other.typeName && s.value == n }
        if case .number=self,case .typed=other { return other.same(self) }
        switch (self,other) {
        case (.null,.null): return true
        case (.bool(let a),.bool(let b)): return a == b
        case (.number(let a),.number(let b)): return a == b
        case (.string(let a),.string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.typed(let a),.typed(let b)): return a == b
        case (.array(let a),.array(let b)): return a.count == b.count && zip(a,b).allSatisfy { $0.same($1) }
        case (.object(let a),.object(let b)): return a.count == b.count && a.allSatisfy { key,value in b[key].map { value.same($0) } ?? false }
        default: return false
        }
    }
    func matchesDisplay(_ other: JSONNode) -> Bool {
        switch (self,other) {
        case (.typed(let s),.number(let n)): return s.display.utf8.elementsEqual(n.utf8)
        case (.typed(let s),.string(let n)): return s.display.utf8.elementsEqual(n.utf8)
        case (.number(let a),.number(let b)):
            if typeName == "DOUBLE" { return Double(a) == Double(b) }
            return a == b
        case (.array(let a),.array(let b)): return a.count == b.count && zip(a,b).allSatisfy { $0.matchesDisplay($1) }
        case (.object(let a),.object(let b)): return a.count == b.count && a.allSatisfy { k,v in b[k].map { v.matchesDisplay($0) } ?? false }
        default: return same(other)
        }
    }
}
struct JSONDocumentParser {
    let bytes:[UInt8]
    var index=0
    var rawNumbers=false
    mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte:UInt8) -> Bool {
        space(); guard index < bytes.count && bytes[index] == byte else { return false }; index += 1; return true
    }
    mutating func string() throws -> String {
        space(); let start=index
        try jsonRequire(index < bytes.count && bytes[index] == 34,"expected JSON string"); index += 1
        while index < bytes.count {
            let byte=bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index])) }
            try jsonRequire(byte >= 32,"unescaped JSON control character")
            if byte == 92 { try jsonRequire(index < bytes.count,"truncated JSON escape"); index += 1 }
        }
        throw DecoderError(code:2,offset:0,reason:"unterminated JSON string")
    }
    mutating func value(depth:Int) throws -> JSONNode {
        try jsonRequire(depth <= 100,"JSON depth exceeds 100")
        space(); try jsonRequire(index < bytes.count,"missing JSON value")
        switch bytes[index] {
        case 34: return .string(try string())
        case 91:
            index += 1; var values:[JSONNode]=[]
            if take(93) { return .array([]) }
            repeat { values.append(try value(depth:depth+1)) } while take(44)
            try jsonRequire(take(93),"missing JSON array end"); return .array(values)
        case 123:
            index += 1; var members:[Data:JSONNode]=[:]
            if take(125) { return .object([:]) }
            repeat {
                let key=Data(try string().utf8)
                try jsonRequire(members[key] == nil,"duplicate JSON key")
                try jsonRequire(take(58),"missing JSON member colon")
                members[key]=try value(depth:depth+1)
            } while take(44)
            try jsonRequire(take(125),"missing JSON object end"); return .object(members)
        case 110,116,102:
            let word=bytes[index] == 110 ? "null" : bytes[index] == 116 ? "true" : "false",end=index+(bytes[index] == 102 ? 5 : 4)
            try jsonRequire(end <= bytes.count && bytes[index..<end].elementsEqual(word.utf8),"invalid JSON literal")
            index=end; return word == "null" ? .null : .bool(word == "true")
        default:
            let start=index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            let token=String(decoding:bytes[start..<index],as:UTF8.self)
            try jsonRequire(token.range(of:#"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,"invalid JSON number")
            if rawNumbers { return .number(token) }
            if !token.contains(".") && !token.lowercased().contains("e") {
                if let n=Int64(token) { return .number(String(n)) }
                if let n=UInt64(token) { return .number(String(n)) }
                throw DecoderError(code:4,offset:0,reason:"JSON integer exceeds 64-bit range")
            }
            guard let n=Double(token),n.isFinite else { throw DecoderError(code:4,offset:0,reason:"non-finite JSON double") }
            return .number(String(n))
        }
    }
}
