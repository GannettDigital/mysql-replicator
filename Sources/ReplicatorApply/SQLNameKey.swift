import Foundation

/// MySQL does not merge Unicode normalization forms in object names. Swift
/// String equality and hashing do. Keep cache keys in their original UTF-8 bytes.
struct SQLNameKey:Hashable,Comparable,ExpressibleByStringLiteral,CustomStringConvertible {
    private let bytes:Data
    init(_ value:String) { bytes=Data(value.utf8) }
    init(stringLiteral value:String) { self.init(value) }
    static func table(_ database:String,_ table:String) -> Self { Self(database+"\0"+table) }
    static func < (lhs:Self,rhs:Self) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
    var description:String { String(decoding:bytes,as:UTF8.self) }
}

enum SQLTextBytes {
    static func equal(_ a:String,_ b:String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func equal(_ a:String?,_ b:String?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case (.some(let a),.some(let b)): return equal(a,b)
        default: return false
        }
    }
}
